# SOLUTION

What was built, why it is shaped this way, and the judgement calls behind it.
The short answers to `docs/DESIGN_QUESTIONS.md` are at the end and link back
into the longer sections.

## Running it

`bin/setup`, then `bin/dev`, then http://localhost:3000/demo — the full walk
(prerequisites, seeded logins, every URL, the tamper demo) is in
[`README.md`](README.md). `bin/ci` runs rubocop, brakeman and the whole suite.

---

## 1. The shape of the system

```
buyer's page (cross-origin)
  └── super-pixel.js ──► POST /api/pixel/visit            (Visit: the browsing IP)
                    ──► POST /api/pixel/leads             (one transaction, below)
                    ◄── WS /cable VerificationChannel     (signed stream token)
                    ◄── GET /api/pixel/leads/:id/activity (same frames, polling)

POST /api/pixel/leads — one transaction:
  Lead + VerificationRun + 10 pre-created LayerResults
  + credit reservation (ledger row) + audit events
  └─ after commit: VerificationLayerJob × enabled layers   (Sidekiq, parallel)

each layer job:  claim row (CAS pending→processing)
                 → Providers::Gateway (fixture store / identity match / clean default)
                 → persist outcome → audit → broadcast rides the audit write
last finisher:   CompletionGate (CAS running→finalizing, exactly one winner)
                 → FinalizeRunJob → Consensus::Engine → verdict (+policy snapshot)
                 → Certificates::Issuer (canonical hash, per-account chain)
                 → Credits::Settlement (refund what never ran) → lead denormalized
```

Everything the pixel and the engine do writes an `AuditEvent`. The live panel,
the CRM's live updates, the lead's activity timeline, and both audit explorers
are four readings of that one table — there is no second event system.

### Core models (Q1)

- **Account → Users, Pixels.** A pixel carries its `public_key` (embeds in the
  snippet), `allowed_domains`, and `enabled_layers` — the account's purchased
  modules ∩ the pixel's own list is what actually runs.
- **Visit** — the page-load beacon: the browsing IP later compared against the
  submit IP, plus the client-side interaction summary, keyed by the pixel's
  `session_id`.
- **Lead** — the submitted person, with identity stored twice: as typed, and
  normalized (`email_normalized`, `phone_normalized`) for matching, search and
  fixture lookup. `status`/`verdict`/`flags` are denormalized here for list
  views; the truth lives below.
- **VerificationRun** — one attempt to verify a lead (unique per lead today; a
  re-funded hold gets a fresh run). Carries `reserved_credits`/`settled_credits`
  and the status machine `pending → running → finalizing → completed`.
- **LayerResult** — one row per layer per run, **pre-created at ingestion**, so
  "not enabled" is a fact from t0 rather than an inference from absence, and a
  layer job's idempotency is a row-level compare-and-set.
- **ConsensusVerdict** — the decision: verdict, score, ordered reasons, flags,
  `hard_stop_layer`, and a **policy snapshot** (the exact weights, hard-stop
  set and thresholds used), so every verdict stays explainable after a buyer
  retunes policy.
- **ConsentCertificate** — the evidence bundle plus `evidence_hash`,
  `previous_hash` and a per-account gapless `sequence_number` (§6 below).
- **CreditLedgerEntry** — append-only money movements; the balance column on
  accounts is a cached projection of this ledger.
- **AuditEvent** — the spine (§2).
- **CrmRecord** — the buyer's existing book, which duplicate detection matches
  against; ACCEPTed leads are appended so tomorrow's resubmission is caught.
- **ProviderResponse** — the seeded vendor answers the Gateway reads.

### The three layer states (Q2)

`layer_results.status` is a string enum:
`not_enabled | not_applicable | pending | processing | completed | errored`.
The first two and the last are the rubric's three states plus the honest fourth
(errored — the vendor never answered); `pending`/`processing` are lifecycle. All
ten rows exist from ingestion, so a certificate can show "voice: not enabled"
as a recorded fact, a dashboard renders three distinct badges ("Not in plan",
"N/A", a pass/warn/fail verdict), and nothing is ever inferred from a missing
row. An unavailable layer is never presented as a passed check.

---

## 2. The audit spine

**Rule: if it happened, there is an AuditEvent row** — ingestion, every layer
start/finish/error, consensus, certificate issuance, every credit movement,
logins and failures, every admin mutation (pixel created/updated, with the
changed fields), every rejected or throttled API call, every replay, every
failed hand-off to the queue.

The write path is one class (`Audit::Recorder`); event names are frozen
constants (`Audit::Events`) so queries can rely on them; the model is
append-only (`readonly?` after persist, no `updated_at`, no update/destroy
routes). The recorder never takes down business flow in production (log and
continue) but always raises in dev/test, so a broken audit write cannot ship
silently.

`Realtime::Broadcaster` hangs off the recorder: the panel and the CRM stream
are *renderings of audit writes*, which is why they can never show something
the trail does not have.

One deliberate boundary: field focus/blur churn stays client-side (the panel
renders it locally); only a capped summary is persisted, once, on the Visit at
submit time. Keystrokes never flood the audit table.

---

## 3. Ingestion, the pipeline, and the races it refuses to lose

Ingestion is a single transaction (lead + run + ten layer rows + reservation +
audits) so a crash mid-way leaves nothing half-built. Jobs are enqueued **after
commit** — Sidekiq's queue is a different datastore, and an in-transaction
enqueue can be executed by a worker before the rows exist.

Idempotency is layered, and the database is the last line of defense:

| Race / retry | Guard |
|---|---|
| double-submitted form (double-click, browser retry, beacon replay) | unique `(pixel_id, session_id)` → answered 200 with the original lead |
| two submissions racing the pre-check | both `RecordNotUnique` and `RecordInvalid` read as replay |
| one layer job delivered twice | CAS claim `pending → processing`; terminal rows decline |
| two last layers finishing together | `CompletionGate`'s conditional UPDATE — exactly one finalizer |
| finalizer retried after a crash | unique indexes on verdict/certificate per run + ledger `(run, entry_type)` — a retry changes nothing |
| worker killed mid-layer | claims go stale after 5 minutes and may be retaken |
| charge written twice | unique `(verification_run_id, entry_type)` on the ledger |

**Queue-outage contract:** Redis being down never loses a lead. The rows are
committed, the API still answers 201, `system.enqueue_failed` is recorded, and
the run is recoverable two ways: the lead's **Re-verify** button, and
`bin/rails verification:requeue_stuck` — both through `Verification::Resumer`,
which restarts whichever stage was lost (layers never dispatched; run finished
but never claimed; claim taken but the finalizer never reached the queue).
Drilled live against a stopped Redis, not just in specs.

---

## 4. The consensus engine (Q3, Q4)

`Consensus::Engine` is a pure decision: it persists nothing and broadcasts
nothing (the finalizer does). Resolution order:

1. **Resolve policy**: layer defaults (`layer_definitions`, seeded) ⊕ the
   account's `layer_policies` overrides ⊕ account threshold overrides, snapshot
   onto the verdict.
2. **Hard stops** — first match rejects with score 0 and a reason naming the
   layer:

   | Layer | Condition | Why it cannot be outweighed |
   |---|---|---|
   | blacklist_alliance | confirmed `litigator` | the lawsuit costs more than any lead is worth |
   | dnc | `dnc_listed` / `internal_dnc` | can't call it → don't buy it |
   | trustedform | `mismatch` / `not_found` / `expired` | consent cannot be proven |
   | anura | `bad` (bot/malware) | not a person |
   | duplicate_detection | exact duplicate (phone AND email in the buyer's CRM) | they already paid for this person |

   "Suspected litigator" is deliberately **not** a hard stop by default — it is
   a −25 signal a buyer can promote (Q6).
3. **Weighted scoring** from 100, over layers that completed. `not_enabled` and
   `not_applicable` contribute nothing — a lead is never penalized for a module
   the buyer didn't buy. The defaults (data, not code):

   | Signal | Δ |
   |---|---|
   | anura suspect / + anonymizer / + fraud farm | −15 / −35 / −50 |
   | vpn: anonymizing network / medium risk / visit-vs-submit IP mismatch | −25 / −5 / −10 |
   | phone: providers disagree / consensus invalid / all agree VoIP / line-type split | −20 / −30 / −15 / −5 |
   | email: both undeliverable / split / disposable | −35 / −15 / −25 |
   | enrichment: no match to the lead / sources disagree | −20 / −12 |
   | blacklist: suspected (unconfirmed) | −25 |
   | voice: synthetic / reused actor | −50 |
   | duplicate: same phone, different email, within ±30 days | −10 + `soft_duplicate` flag, never auto-reject |

4. **Bands**: ≥ 70 ACCEPT · 40–69 REVIEW · < 40 REJECT (account-overridable).
5. **Reasons**: one line per layer that moved the score, largest impact first,
   carrying the layer's own sentence about what it found.

Three honesty rules sit on top. A **required** layer that errors caps the verdict
at REVIEW (Q5); an accept requires at least one layer to have actually answered —
a run where everything errored or was skipped reaches 100 having verified nothing,
and is capped at REVIEW rather than certified on no evidence; and a **required
layer the lead gave nothing to judge** caps it for the same reason.

That third rule closes a gap the first two leave open, and it is the one an
author of leads controls. Every vendor fixture answers about an identity rather
than refusing an unusable one, so a junk identity used to collect clean passes
from every layer that keys on it. Three defences, at increasing depth:

1. **The front door.** A lead needs one identity somebody could actually reach.
   A **dialable phone** (`Leads::Normalizer.dialable?`) is both a length and a
   shape: 10–15 digits, NANP's national length up to E.164's maximum, arranged
   as runs of digits with at most one separator between two runs and a `+` only
   at the front. Counting alone is not enough — `9+30976543234567` is fifteen
   digits with a plus wedged into the middle of them. A **deliverable address**
   (`deliverable_shape?`) needs a dotted domain, since `type="email"` and RFC
   5322 both accept `fghjk@njjj`: a dotless host is legal mail on a local
   network, and a lead's address is not local. Neither present is a **422 before
   a credit is reserved**, extending the rule that already refused a lead whose
   identity was whitespace.

   Both shapes are single constants (`DIALABLE_SHAPE`, `DELIVERABLE_SHAPE`), and
   the demo form's `pattern` attributes are **rendered from them** — the browser's
   rule and the server's rule are the same string, so the courtesy check cannot
   drift into accepting what ingestion refuses. (HTML compiles `pattern` with the
   regex `v` flag, where an uncompilable pattern is silently ignored rather than
   reported; a system spec asserts `validity.patternMismatch` field by field
   instead of trusting that the form merely failed to submit.)
2. **The layers that key on the missing half.** A lead reachable by phone may
   still carry nonsense where its address is, and vice versa. DNC, litigator
   screening and phone consensus report `not_applicable` without a dialable
   number; email consensus does the same without a deliverable address. Two of
   those are *required*, so the verdict caps at REVIEW with flag
   `required_layer_unjudged`, and settlement refunds the checks that never ran.
3. **What no shape check can reach.** `+930976543234567` is fifteen digits — a
   legal E.164 length on an unassigned country code — and `jane@example.com`
   might belong to nobody. Whether a *possible* identity is a *real* one is
   exactly the question the phone, email and enrichment layers exist to answer,
   and in this build those vendors are fixtures: `Providers::Gateway` answers an
   identity it has never seen with a clean default, by design (§11). The demo
   therefore accepts a plausible-looking invention, and a reviewer should read
   any 100 on a hand-typed lead as "the mock vendors had nothing against it",
   not as "verified".

### Calibration against the twelve (not hardcoded)

`expected_verdict` is stripped on import and read only by the seed report and
the harness spec. The engine derives, through each lead's own account and its
enabled modules:

| Lead | Derived | Score | Via |
|---|---|---|---|
| L-1001 | accept | 100 | all enabled layers passed |
| L-1002 | reject | 0 | hard stop — Anura `bad` (bot/malware) |
| L-1003 | review | 65 | Anura suspect + anonymizer (−35) — via Anura, since MedicareEdge has no vpn_proxy module |
| L-1004 | reject | 0 | hard stop — exact duplicate of CRM ME-88213, flag `duplicate` |
| L-1005 | reject | 0 | hard stop — **DNC** (AutoInsure doesn't buy the litigator layer; the verdict had to come from a module it owns) |
| L-1006 | reject | 0 | hard stop — DNC listed |
| L-1007 | review | 60 | phone providers disagree (−20) + anura suspect (−15) + vpn medium risk (−5) |
| L-1008 | review | 65 | email 2/2 undeliverable (−35) — the Cyrillic-homoglyph address is the *provider's* catch, not string tricks in our normalizer |
| L-1009 | reject | 35 | anura fraud-farm (−50) + all-VoIP consensus (−15) — agreement on VoIP is a different signal from disagreement |
| L-1010 | reject | 0 | hard stop — TrustedForm cert mismatch |
| L-1011 | review | 58 | blacklist suspected (−25) + enrichment disagreement (−12) + line-type split (−5) |
| L-1012 | accept | 90 | soft duplicate (−10) + flag — surfaced for a human, never auto-rejected |

`db:seed` prints this table with live derivations and fails visibly on drift;
`spec/seeds/harness_spec.rb` is the same net in CI.

---

## 5. Credits (Q9, Q10)

**Per layer, reserved per run, settled at the end** — the fixtures' own
`module_costs_in_credits` makes flat-rate pricing a fiction, and billing at
completion means work is performed before it is known to be fundable.

- **Reserve at ingestion**, inside the ingestion transaction, under a row lock
  on the account: Σ cost of the effective layers (17 / 21 / 8 per seeded
  account). The ledger row carries the per-layer breakdown and `balance_after`.
- **Settle at finalization**: refund the cost of layers that ended
  `not_applicable` or `errored` — we don't bill checks that didn't run.
- **Zero mid-verification is impossible by construction**: the run was funded
  before any layer started. Insufficient at ingestion → the lead is kept,
  status `on_hold_insufficient_credits`, answered 402, re-runnable from the
  dashboard after a top-up (drilled in the browser: guard while still short,
  restart once funded).
- The ledger is append-only and authoritative; `credit_balance` is a cached
  projection. `balance == Σ(ledger)` is asserted by specs, by
  `bin/rails credits:audit`, and held under threaded contention tests.
- **Burn rate** = trailing 7-day net spend from the ledger; while the ledger
  is younger than a full window, the higher of observed and the plan's stated
  `avg_daily_burn` wins — understating burn is the expensive mistake for a
  warning light. **Runway** = balance / burn. The platform console flags
  `past_due` status and runway below three days; seeded AutoInsure trips both
  (80 credits ÷ 410/day ≈ 0.2 days), and crossing the threshold at settlement
  also writes an `account.flagged_low_credits` audit event so the warning has
  a queryable trail.

---

## 6. Consent certificates (Q11)

Evidence captured per certificate: the lead's identity snapshot, pixel and
page context, session with visit-vs-submit IPs, **all ten layers with the
state each ended in**, the verdict with score/reasons/flags, the full policy
snapshot, the TrustedForm reference and its match/expiry fields, timestamps,
engine version.

Tamper-evidence is two mechanisms:

1. `evidence_hash` = SHA-256 over **canonical JSON** (recursively key-sorted).
   Postgres `jsonb` does not preserve key order, so hashing `to_json` at
   issuance breaks verification after one round-trip — canonicalisation is
   what makes the hash stable, and there is a regression spec for exactly
   that.
2. A **per-account hash chain**: `previous_hash` + gapless `sequence_number`
   (issued under an advisory lock). Editing one historical certificate —
   even rewriting its digest consistently — breaks every later link.

Verification is recomputation, never a stored flag: the dashboard page, the
**public** `/verify/:cert_id` page (and `.json`) all re-derive the digest in
front of the reader. Immutability is `readonly?` + no update routes + no
`updated_at`; the database deliberately allows raw-SQL tampering so the
tamper demo is honest. Both failure modes were
demonstrated live: an evidence edit (hash mismatch) and a consistent forgery
(later certificate reports the broken chain).

---

## 7. Multi-tenancy & authorization (Q7, Q8)

Isolation is enforced four times over, and the interesting part is that each
layer assumes the others failed:

1. **acts_as_tenant with `require_tenant = true`** — every tenant model is
   scoped by default, and an unscoped query *raises* instead of returning the
   world. Exceptions are explicit `without_tenant` blocks, greppable, each
   with a reason.
2. **Association loading** — controllers load through
   `current_account.leads.find_by!(public_id:)`, so even a misconfigured gem
   leaves nothing reachable.
3. **Pundit, default-deny** — roles on top of tenancy: members read,
   account_admins manage pixels and re-verifications, nothing is granted by
   omission. The policy matrix is specced role × action.
4. **The database** — every tenant table carries `account_id` with FK
   constraints and composite indexes.

Cross-tenant reads answer **404, never 403** — existence is not revealed. The
pixel API derives the tenant **from the key alone**; `account_id`/`pixel_id`
in a payload are accepted (the reference snippet sends them) and ignored, so
posting a lead into someone else's account is impossible by construction, not
by validation.

`super_admin` is contained rather than trusted (Q8): no tenant of their own,
a separate `Admin::` namespace whose base controller opts out of tenancy
explicitly per request, **read-only** surfaces (changing a buyer's balance is
a billing action, not a console one), Sidekiq Web behind a routing constraint
that 404s for everyone else, and every admin mutation audited. Leaks are
specced: an account admin and a member get 404 on `/admin`; a super_admin
gets 404 on `/app/*` (they have no account to view).

## 8. Pixel security (the pixel-spec questions)

- **What lives client-side is public by definition**: the pixel key, page
  context, and what the visitor typed. Verdicts, evidence, credits, module
  lists and account bindings never leave the server.
- **A stolen key** is bounded by the per-pixel `allowed_domains` allowlist
  (Origin/Referer check) — a snippet run from anywhere else gets 403 and an
  audit row.
- **Replay** is idempotent, not an error: unique `(pixel_id, session_id)`
  answers the original lead with 200. The stream token is only re-issued when
  the resubmission's normalized identity matches — session ids are
  client-generated and guessable, so naming one is not enough to be handed a
  live feed of someone else's verification. The 200 carries `replayed: true` and
  **the panel says so**: it is about to replay that lead's history, which paints
  the same layers and the same banner as a fresh run, and a silent replay is
  indistinguishable from a second verification that happened to agree. The demo
  form also holds its own submit button until the verdict lands — the server is
  what makes a double-click harmless, but a form that invites the click invites
  the doubt.
- **Stream auth**: the 201 carries a signed, 15-minute, single-lead token
  (`Rails.application.message_verifier`); the Cable channel and the polling
  endpoint both verify it and reject without it. Cable's origin forgery
  protection is off deliberately — buyer domains cannot be enumerated — the
  token *is* the boundary.
- **CORS** is open for `/api/pixel/*` only (the pixel is cross-origin by
  definition, credentials off); rack-attack throttles per key and per IP with
  429 + `Retry-After`, audited.
- **Input trust**: IP and user agent come from the connection, never the
  payload; a page-supplied `submitted_at` is ignored because it is an input
  to scoring (duplicate recency, TrustedForm expiry).
- **Capture fidelity**: the submit serializer carries checkable fields
  (checkbox/radio) only when actually checked — a checkbox's `.value` reads
  "on" whether or not it is ticked, and `raw_payload` is consent evidence, so
  the box is recorded as the visitor left it, exactly as a native form post
  would carry it. Whether consent is *provable* remains the TrustedForm
  layer's voice. The demo form additionally marks the box `required` and
  constrains the phone field's shape: a lead the buyer could never legally dial
  is refused by the browser before a request is made or a credit spent. Those
  are courtesies, not controls — the browser belongs to whoever is submitting,
  so every one of them is enforced again server-side, and the pixel itself stays
  permissive because the buyer pages it is dropped on may not have the
  attributes at all (a system spec strips them to emulate one that does not).

## 9. Real-time (Q12, Q13)

**Background jobs, always** (Q12): ten vendor calls at 250–900 ms each are
2.5–9 s serial — unacceptable inside a POST from somebody's funnel, and a
crash mid-sequence would lose half a verification. Parallel jobs finish in
roughly the slowest layer's time, retry independently, and the enqueue-after-
commit + at-least-once discipline is exactly what the idempotency table in §3
exists for. The trade — accepted — is that the POST cannot return a verdict,
which is what the real-time channel is for.

**Action Cable over SSE/polling** (Q13): Redis is already in the stack for
Sidekiq, so Cable's pub/sub costs no new infrastructure; one broadcast feeds
both the visitor's panel (raw WebSocket, hand-rolled ~60-line wire client in
`super-pixel.js` — no bundler or CDN on a buyer's page) and the buyer's CRM
(Turbo Streams). Traded away: a connection per visitor is heavier than SSE,
and WebSockets die under some proxies — which is why the transport is a
ladder, not a bet:

```
socket → 5 reconnects (capped backoff) → 3s polling — same frames, same token
```

Every frame carries its audit event id on both transports; the pixel
deduplicates by id and starts every confirmed subscription with a catch-up
read (frames written before the page could subscribe — the reserved-credits
row always — are otherwise structurally unreachable on the socket path). A
server that accepts the socket but answers the subscribe with silence is
treated as a rejection after four seconds. Everything stops at the verdict
(plus a two-second linger for the certificate/settlement rows) or at a hard
five-minute deadline — no immortal timers on a buyer's page. The polling
endpoint's cursor advances past *examined* events, not just rendered ones, so
a run whose latest events are unrenderable cannot wedge the poller.

The panel is best-effort by design: broadcasts that fail are logged and
swallowed, because the database row is the truth and polling can re-read it.

## 10. Testing

Highest-value first, per the rubric: the consensus engine (every hard stop,
band edges 39/40/69/70, exclusions, fail-open/closed, policy overrides), the
**12-lead harness** (the "defensible against the seeds, not hardcoded" net),
tenant isolation by direct id for every resource, credit atomicity under
threads, job idempotency and the double-finalize race, certificate
canonical-hash stability across a jsonb round-trip and chain breakage, the
audit taxonomy for one full run, and three system specs driving real browsers
— sign-in, the demo page end-to-end (including held jobs so the panel is
proven to stream, not assumed), and the CRM growing a row live.

`bin/ci`: rubocop (rails-omakase, zero offenses), brakeman (zero warnings),
~800 examples.

## 11. What is stubbed, and what was cut

Stubbed, per the assignment's explicit permission:

- **Vendor calls** — `Providers::Gateway` reads the seeded fixture store:
  exact match by lead ref, then by normalized identity (typing a persona into
  the live demo replays its scenario), then deterministic clean defaults so an
  unknown identity verifies instead of erroring; simulated 250–900 ms latency
  in dev, zero in test. The seam is one class — swapping in HTTP clients
  changes nothing around it.

  **The consequence, stated plainly:** a hand-typed identity nobody has ever
  seen passes every vendor layer, because a fixture store has nothing against
  it. That is the right default for a demo — the alternative is a landing page
  where no real visitor can ever be accepted — but it means a 100 on an invented
  lead measures the absence of a fixture, not the presence of a person. Shape
  checks (§4) refuse identities that are *impossible*; only real vendors can
  refuse ones that are merely *untrue*. Every seeded persona, by contrast,
  derives its verdict from recorded vendor answers.
- **Email delivery** — nothing sends mail; users are seeded/invited.
- **Payments/top-ups** — credit grants and adjustments exist only as seeded
  ledger entries; there is no billing UI. (Voice samples similarly arrive
  only via fixtures — `has_sample: false` is `not_applicable`, which is the
  honest state for an in-development module.)
- **i18n** — deliberately skipped for a single-locale take-home.

**Nothing was cut from the planned scope.** The allowed-cut list (account
audit explorer, re-verify button, admin drill-down) all shipped.

## 12. Next week, and the risks I'd watch (Q14)

First thing next: **compute visit-vs-submit IP mismatch ourselves.** The VPN
layer currently reads that comparison from the provider payload; both IPs are
already first-hand data on our own rows. It is the one
signal we can observe rather than buy, and it is a two-line change in the
processor plus recalibration checks.

Then, in order: an account settings screen for thresholds/weights (with the
`review ≤ accept` validation that currently exists nowhere because the input
surface doesn't either), per-account webhooks on `verdict.issued` (the audit
spine is already the outbox), a verdict override workflow with dual-control
audit for the review queue, certificate export (PDF/JSON bundle for a
regulator), provider circuit breakers in the Gateway seam, and audit-table
partitioning by month once volume justifies it.

Biggest risks in the current design, named honestly:

1. **The audit table is a single hot append target.** Every action writes to
   it; at real volume it needs partitioning and a retention policy. The
   indexes are already shaped for the queries, but growth is unbounded today.
2. **rack-attack counters are per-process** — a
   multi-process deployment multiplies the effective limits until the store
   moves to the Redis already in the stack. One line, deliberately deferred.
3. **Policy tuning has no guardrails yet** — an inverted threshold pair would
   be honored (and visibly snapshotted). The validation belongs on the entry
   form that doesn't exist yet; until it does, this is operator territory.
4. **One run per lead** — re-verification after a hold creates a fresh run,
   but there is no run *history* per lead (a re-verify replaces the story
   rather than versioning it). The audit trail preserves everything, but a
   first-class lead-version model would make comparisons a query.

---

## Design questions, answered short (Q1–Q14)

1. **Core models & where a verification run lives** — §1. A `VerificationRun`
   is its own row between Lead and LayerResults/Verdict/Certificate: leads are
   what buyers own, runs are attempts, and separating them is what makes
   re-verification, idempotency and the status machine clean.
2. **Three layer states** — §1: a string enum on pre-created rows;
   `not_enabled` / `not_applicable` / `completed` are recorded facts, never
   inferred from absent rows; `errored` is honestly distinct.
3. **Hard stops vs weighted signals** — §4: legal/consent certainties
   (litigator, DNC, unprovable consent, bot, exact duplicate) stop; opinions
   and single-vendor doubts weigh. The line is "would any score make this
   lead buyable?".
4. **N results → verdict + reason** — §4: policy resolve → hard stops →
   weighted sum from 100 over answered layers → bands (70/40) → one reason
   line per contributing layer, biggest first.
5. **Required layer unavailable** — §4: fail *closed to REVIEW* (never
   auto-ACCEPT a compliance gap, never destroy a possibly-good lead);
   optional layers fail open with the error recorded and visible. Plus: an
   accept requires at least one answered layer.
6. **Buyer tuning** — policy is **data**: per-layer weights and
   `treat_as_hard_stop` in `layer_policies`, thresholds in account settings,
   resolved per run and snapshotted onto the verdict. Promoting "suspected
   litigator" to a hard stop is a row update, no deploy.
7. **Query-layer isolation** — §7: acts_as_tenant with `require_tenant`
   raising, association-rooted loading, Pundit default-deny, DB constraints;
   cross-tenant probes answer 404 and are specced by direct id for every
   resource.
8. **super_admin containment** — §7: separate namespace, explicit per-request
   tenancy opt-out, read-only console, constrained Sidekiq Web, every admin
   action audited.
9. **When is a credit consumed** — §5: reserved per run as Σ(enabled layer
   costs) at ingestion, settled at finalization with refunds for layers that
   didn't run. Per-lead flat pricing ignores the fixtures' own cost table;
   per-layer-at-completion bills after the work. Reserve-then-settle is how
   you never do unfunded work *and* never charge for a check that didn't
   happen.
10. **Zero credits** — §5: mid-verification is unreachable (funded up front);
    at ingestion it's a kept, re-runnable held lead + 402. The console shows
    balance, burn, runway; it warns at `past_due` and < 3 days runway, with
    an audit event at the crossing. AutoInsure lights up on both.
11. **Certificate contents & tamper-evidence** — §6: identity, session and
    both IPs, all ten layer states, verdict + reasons + policy snapshot,
    TrustedForm reference; canonical-JSON SHA-256 plus a per-account hash
    chain, recomputed publicly at `/verify/:id`.
12. **Sync or jobs** — §9: jobs, for latency, isolation and retryability;
    the cost (no verdict in the POST response) is exactly what the real-time
    channel repays.
13. **Transport** — §9: Action Cable (zero new infrastructure, one broadcast
    for two consumers), traded against per-visitor connection weight and
    proxy fragility — mitigated by the socket → reconnect → polling ladder
    with id-deduplicated frames.
14. **Next & riskiest** — §12: first-hand IP-mismatch signal next; the audit
    table's growth, per-process throttles, unguarded policy tuning, and
    single-run-per-lead are the risks I'd name before anyone asks.
