# CLAUDE.md — Super Pixel Platform · Build Plan (v2)

This file is the single source of truth for building this assignment. It supersedes
`CLAUDE_1.md` (kept for reference; §21 lists every deliberate change and why).
Read `ASSIGNMENT.md`, `docs/DESIGN_QUESTIONS.md`, `docs/provider-modules.md`,
`docs/data-contracts.md`, `docs/pixel-spec.md`, and `EVALUATION.md` before coding.

**The five non-negotiables for this build:**
1. **Audit logging of everything.** One append-only, indexed, queryable event spine
   powers the activity timeline, the real-time panel, and compliance queries.
2. **Professional error handling.** Nothing breaks: typed failures, consistent
   envelopes, idempotent jobs, deliberate fail-open/fail-closed per layer, and a
   pixel that never damages the host page.
3. **Rails conventions and craft, done properly.** Single Responsibility
   everywhere — every class has one reason to change. Thin controllers, thin
   models, service objects with Result values, DB-enforced invariants,
   query-layer tenancy, meaningful names. Full standards: §18.1 — they are
   rules, not suggestions.
4. **Depth over breadth**, in the assignment's priority order. Cut from the bottom
   of §20, never from the top.
5. **Nothing ships unfinished — strictly.** Implementation follows the chunk list
   in §20 in order, one chunk at a time, each with a verifiable "Done when". No
   TODOs, no dead stubs, no silently skipped scope, no half-wired features. The
   completeness audit (chunk 6.6) must pass before the work is called done.

---

## 1. What we are delivering

- Multi-tenant Rails app: auth, roles, pixel management, lead ingestion API,
  parallel detection-layer pipeline, consensus engine, consent certificates,
  per-account CRM, credit accounting, super-admin dashboard, audit explorer.
- A **real** real-time landing page at `/demo` — the bundled simulation replaced by
  live ActionCable events from actual verification jobs.
- `SOLUTION.md` answering all 14 design questions (outline in §22).
- Seeds that load every `mock-data/` file and **process the 12 leads through the
  real engine** (never hardcoding `expected_verdict`), printing a derived-vs-hint
  verdict table at the end of `db:seed`.
- RSpec suite focused on: consensus engine, tenant isolation, credit atomicity,
  job idempotency, certificate tamper-evidence.

---

## 2. Stack (and why — interview-defensible)

| Choice | Why |
|---|---|
| **Rails 8.x, Ruby 3.3+** | Current major with modern defaults (`params.expect`, omakase rubocop); every gem below fully supports it. |
| **PostgreSQL** | `jsonb` + GIN for audit/evidence queries, partial/composite indexes, row locks, CHECK constraints. Audit queries are a first-class requirement. |
| **Sidekiq + Redis** (jobs) | Battle-tested, operated fluently by the presenter — demo defensibility is a stated requirement. Queues per pipeline stage (`ingestion`, `layers`, `finalize`), exponential retry, Sidekiq Web mounted super_admin-only. Discipline required: **enqueue only after commit** (§8) and **Redis-down never loses a lead** (§7.4). |
| **ActionCable (Redis adapter)** | Rails-native WebSocket for the pixel panel + Turbo Streams from one broadcast; Redis is already in the stack for Sidekiq, so pub/sub costs no new infrastructure. |
| **Devise** (`database_authenticatable`, `rememberable`, `validatable` — `registerable` **off**) | Industry-standard auth the presenter knows end-to-end. Login-only surface: users are seeded/invited, no self-registration; brute-force throttled via rack-attack. |
| **Pundit** | Explicit, testable role authorization (second layer after tenancy). |
| **acts_as_tenant** | Query-layer isolation + auto tenant assignment + tenant-scoped uniqueness. We *also* load through `current_account` associations — belt and braces. |
| **Hotwire (Turbo + Stimulus), Tailwind, Pagy** | Clean legible UI cheaply; Turbo Streams give the CRM live updates for free off the same broadcasts. |
| **rack-cors + rack-attack** | Pixel endpoints are cross-origin and abusable: CORS allowlist + throttles are table stakes. |
| **RSpec + FactoryBot + Capybara** | Standard; system specs only for the two golden paths. |

No state-machine gems, no unneeded abstractions. Every dependency must be
explainable in one sentence — and familiarity is an engineering criterion here:
the follow-up interview requires defending every tool live, and Sidekiq, Redis,
and Devise are the pieces the presenter can explain from production experience.
Dev runs via `Procfile.dev` (web, css, sidekiq) with Redis local (brew/docker);
`bin/setup` verifies both Postgres and Redis connectivity and fails loudly with
instructions if either is missing.

---

## 3. Architecture at a glance

```
Landing page (buyer site, cross-origin)
  └── super-pixel.js (served by us, real transport)
        ├── POST /api/pixel/visit           (site-visit beacon → Visit row, visit IP)
        ├── POST /api/pixel/leads           (submit → Lead + VerificationRun, 201 {lead_id, stream_token})
        └── WS  /cable  VerificationChannel (signed stream_token → live events)

Ingestion (one DB transaction):
  Lead + Run + 10 pre-created LayerResults + credit RESERVATION + AuditEvents
  → after commit: LayerJob × N enabled layers (parallel, idempotent)

Each LayerJob:
  Providers::Gateway (fixture lookup by identity, clean fallback, simulated latency)
  → updates its pre-created LayerResult row (CAS: pending→completed)
  → Audit::Recorder.record!("layer.completed", …) → broadcast to panel + CRM

Last finisher (atomic compare-and-set on the run) → FinalizeRunJob:
  Consensus::Engine (policy-driven) → ConsensusVerdict (+ policy snapshot)
  → Certificates::Issuer (canonical-JSON hash, per-account hash chain)
  → Credits::Settlement (refund not_applicable/errored layer costs)
  → run completed + "final_verdict" broadcast + AuditEvents throughout
```

Everything the pixel and the engine do emits an `AuditEvent`; the real-time panel,
the CRM activity timeline, and the audit explorer are three views over that one table.

---

## 4. Canonical layer registry — one set of names, everywhere

The #1 silent demo-breaker is name drift. The canonical keys (matching
`mock-data/providers/*`, `accounts.json#enabled_modules`,
`module_costs_in_credits`, and the landing page's `LABELS`) are:

```
vpn_proxy, anura, trustedform, blacklist_alliance, dnc,
phone_validation, email_validation, enrichment, duplicate_detection, voice
```

`Layers::REGISTRY` (code) maps each key → processor class, panel label, and
position. `layer_definitions` (DB, seeded) holds per-key **cost in credits**,
**hard_stop_capable**, **criticality** (`required`/`optional` → fail-closed/open),
and **default_weights jsonb**. Policy lives in data, not code (rubric standout).
Never introduce an alias (`trusted_form`, `voice_ai`, `duplicate` are all bugs).

Per-account facts (verified against fixtures — calibration depends on them):
- `acct_solarpro` (17 cr/run): all modules except `voice`.
- `acct_medicareedge` (21 cr/run): all except `vpn_proxy` ← L-1003's REVIEW must
  come from Anura alone.
- `acct_autoinsure` (8 cr/run): only `anura, trustedform, dnc, phone_validation,
  duplicate_detection` ← L-1005's REJECT must come from **DNC**, not the (disabled)
  litigator layer; L-1009's REJECT must come from Anura fraud-farm + VoIP.

---

## 5. Data model

Conventions: every tenant-owned table carries `account_id` (uniform query-layer
scoping + composite indexes) even where derivable via joins. Public identifiers are
Stripe-style external ids (`acct_…`, `px_…`, `L-…`, `cert_…`) in a `public_id`
column with a unique index — **never** fixture strings as primary keys (fixture ids
like `acct_solarpro` cannot be bigint PKs; CLAUDE_1.md's seed pattern breaks here).
All enums are string-backed. `null: false` + DB defaults + CHECK constraints where
an invariant exists. Every FK indexed; every WHERE/ORDER column indexed.

```
accounts        public_id*, name, plan, status(active/past_due/suspended),
                credit_balance≥0 (CHECK), monthly_credit_allowance,
                cycle_start, cycle_end, billing_email, settings jsonb
                (settings carries accept/review threshold overrides)

users           account_id (nullable ONLY for super_admin — validated both ways:
                presence unless super_admin, absence if super_admin),
                email*, encrypted_password + rememberable timestamps (Devise),
                name, role(super_admin/account_admin/member)
                — Devise modules: database_authenticatable, rememberable,
                validatable; registerable OFF (seeded/invited users only)

pixels          account_id, public_id* (px_…), name, public_key* (snippet token),
                allowed_domains text[], enabled_layers text[] (subset filter;
                effective set = account modules ∩ pixel layers), active
                — no unused secret_key; stream auth uses signed tokens (§13)

visits          account_id, pixel_id, session_id (client correlation), ip_address,
                user_agent, page_url, referrer, started_at, interactions jsonb
                index (pixel_id, session_id)

leads           account_id, pixel_id, public_id* (L-…), first/last name,
                email, email_normalized, phone, phone_normalized,
                ip_address, user_agent, page_url, session_id, form_dwell_ms,
                status(received/verifying/on_hold_insufficient_credits/completed),
                verdict (denormalized from final verdict, nullable), flags jsonb,
                raw_payload jsonb, submitted_at
                indexes: (account_id, created_at), (account_id, status),
                (account_id, verdict), (account_id, email_normalized),
                (account_id, phone_normalized), unique (pixel_id, session_id) → replay-safe

verification_runs   account_id, lead_id, status(pending/running/finalizing/
                    completed/failed), started_at, completed_at,
                    reserved_credits, settled_credits
                    unique index (lead_id) — one run per lead in v1; re-verify
                    creates a new lead-version later (documented)

layer_results   account_id, verification_run_id, layer_key,
                status(not_enabled/not_applicable/pending/processing/
                       completed/errored),
                verdict (layer-specific string), panel_verdict(pass/warn/fail/skip),
                detail (human sentence for the panel/CRM),
                score_delta int, raw_response jsonb, error_class, error_message,
                started_at, completed_at
                unique (verification_run_id, layer_key) — idempotency backstop
                * not_enabled / not_applicable / completed(returned a verdict) are
                  the three rubric states; pending/processing/errored are lifecycle.

layer_definitions  key*, name, cost_credits, hard_stop_capable,
                   criticality(required/optional), default_weights jsonb, position

layer_policies  account_id, layer_key, enabled, treat_as_hard_stop,
                weight_overrides jsonb — unique (account_id, layer_key)

consensus_verdicts  account_id, verification_run_id (unique), verdict(accept/
                    review/reject), score int, reasons jsonb (ordered list),
                    flags jsonb (e.g. soft_duplicate), hard_stop_layer,
                    policy_snapshot jsonb (exact weights/thresholds used — the
                    verdict is auditable forever even if policy changes), issued_at

consent_certificates  account_id, lead_id, verification_run_id (unique),
                      public_id* (cert_…), verdict, evidence jsonb,
                      evidence_hash (SHA256 over canonical JSON — see §11),
                      previous_hash, sequence_number, trustedform_reference,
                      issued_at, created_at — NO updated_at; model readonly after
                      create; unique (account_id, sequence_number) → per-account
                      hash chain

credit_ledger_entries  account_id, verification_run_id (nullable),
                       entry_type(grant/reservation/settlement_refund/adjustment),
                       amount (signed), balance_after, breakdown jsonb
                       (per-layer costs), memo, created_at — append-only,
                       unique (verification_run_id, entry_type) WHERE run NOT NULL
                       → a retried job can never double-charge

audit_events    §6 — the spine.

crm_records     account_id, external_ref (SP-40021…), first/last name, email,
                email_normalized, phone, phone_normalized, source_created_at
                indexes on (account_id, phone_normalized), (account_id, email_normalized)

provider_responses  layer_key, lead_ref (L-… nullable), email_normalized,
                    phone_normalized, payload jsonb
                    unique (layer_key, lead_ref) — fixture store for the Gateway
```

`Current` (ActiveSupport::CurrentAttributes): `user`, `account`, `request_id`,
`session_id` — stamped in controllers/jobs, consumed by audit + logs.

---

## 6. Audit logging — the spine (most important subsystem)

**Rule: if it happened, there is an AuditEvent row.** Ingestion, every layer start/
finish/error, consensus, certificate issuance, every credit movement, every login
success/failure, every admin mutation (pixel created/updated, policy changed),
every rejected/throttled API call, every replay detection.

```ruby
create_table :audit_events do |t|
  t.references :account, index: false          # nullable: platform-level events
  t.string  :event_type,   null: false          # dot taxonomy, see below
  t.string  :actor_type,   null: false          # "user" / "pixel" / "system"
  t.bigint  :actor_id
  t.string  :subject_type                       # polymorphic: Lead, Pixel, Account…
  t.bigint  :subject_id
  t.string  :request_id
  t.string  :session_id                         # pixel correlation id
  t.string  :ip_address
  t.jsonb   :payload,      null: false, default: {}
  t.datetime :occurred_at, null: false
  t.datetime :created_at,  null: false          # append-only: no updated_at
end
add_index :audit_events, [:account_id, :occurred_at]
add_index :audit_events, [:account_id, :event_type, :occurred_at]
add_index :audit_events, [:subject_type, :subject_id, :occurred_at]
add_index :audit_events, [:event_type, :occurred_at]      # platform-wide queries
add_index :audit_events, :session_id
add_index :audit_events, :payload, using: :gin            # ad-hoc payload queries
```

**Event taxonomy** (stable, documented, `object.verb` past tense — queries depend
on these strings, so they are frozen constants in `Audit::Events`, never inline
literals):

```
pixel.visit_recorded      lead.received            lead.replay_detected
lead.on_hold              verification.started     layer.started
layer.completed           layer.skipped            layer.errored
consensus.evaluated       verdict.issued           certificate.issued
credits.granted           credits.reserved         credits.settled
credits.adjusted          credits.insufficient     auth.login_succeeded
auth.login_failed         auth.logout              pixel.created
pixel.updated             policy.updated           account.flagged_low_credits
api.request_rejected      api.throttled            system.enqueue_failed
```

**Recorder** — the only write path:

```ruby
module Audit
  class Recorder
    def self.record!(event_type, subject: nil, payload: {}, actor: Current.actor)
      event = AuditEvent.create!(
        event_type:, subject:, payload:,
        account_id:  Current.account&.id || subject.try(:account_id),
        actor_type:  actor&.class&.name&.underscore || "system",
        actor_id:    actor.try(:id),
        request_id:  Current.request_id,
        session_id:  Current.session_id,
        ip_address:  Current.ip_address,
        occurred_at: Time.current
      )
      Realtime::Broadcaster.publish(event)   # panel + CRM feed off the same write
      event
    rescue StandardError => e
      # Auditing must never take down the business flow in production —
      # but it must never fail silently in dev/test either.
      raise if Rails.env.local?
      Rails.logger.error("[audit-drop] #{event_type}: #{e.class} #{e.message}")
      Sentry-style hook point; returns nil
    end
  end
end
```

- Model is append-only: `readonly?` after persist, no update/destroy routes,
  no `updated_at`.
- The **activity timeline** on a lead = `AuditEvent.where(subject: lead)` ∪ events
  sharing its `session_id` (visit → submit → layers → verdict → certificate).
- The **audit explorer** (account dashboard + super-admin global) is a filterable
  index over exactly these indexes: by event_type, subject, actor, date range.
- Pixel field focus/blur events stay client-side (panel renders them locally);
  the interaction summary is persisted once on the Visit/Lead — keystroke spam
  never floods the audit table. Documented in SOLUTION.md.

---

## 7. Error handling — the framework (second most important)

### 7.1 Taxonomy

```ruby
module Errors
  class DomainError < StandardError
    def code = self.class.name.demodulize.underscore   # machine-readable
  end
  class ValidationFailed      < DomainError; end
  class PixelNotAuthorized    < DomainError; end
  class OriginNotAllowed      < DomainError; end
  class ReplayDetected        < DomainError; end
  class InsufficientCredits   < DomainError; end
  class InvalidTransition     < DomainError; end
  class ProviderUnavailable   < DomainError; end   # retryable
  class CertificateTampered   < DomainError; end
end
```

### 7.2 Services: one base, one Result — domain failures are values, bugs raise

```ruby
class ApplicationService
  Result = Struct.new(:success?, :value, :error, :code, keyword_init: true) do
    def failure? = !success?
  end
  def self.call(...) = new(...).call

  private

  def success(value = nil)         = Result.new(success?: true,  value:)
  def failure(error, code: nil)    = Result.new(success?: false, error: Array(error), code:)
end
```

- **One** shared Result (CLAUDE_1.md redefined it per class — drift risk).
- Services return `failure(...)` for *expected domain outcomes* (insufficient
  credits, replay, validation). They **do not** blanket-`rescue StandardError` —
  swallowing `NoMethodError` into `["Unexpected error"]` hides bugs and breaks job
  retry semantics. Unexpected exceptions propagate to the boundary that knows what
  to do (controller envelope or job retry).

### 7.3 Controller boundary: one envelope, correct statuses

`Api::Pixel::BaseController` and web controllers use a shared `rescue_from` map —
every error path returns the same shape, always with `request_id`:

```json
{ "error": { "code": "insufficient_credits", "message": "…", "request_id": "…" } }
```

| Condition | Status |
|---|---|
| Unknown/inactive pixel key | 401 |
| Origin not in `allowed_domains` | 403 |
| Cross-tenant record (web) | **404** — never 403; existence is not revealed |
| Role denied within own account (Pundit) | 403 (web: friendly page) |
| Validation | 422 |
| Insufficient credits | 402 |
| Replay (same `pixel_id`+`session_id`) | 200 with the original `lead_id` (idempotent) + `lead.replay_detected` audit |
| Throttled (rack-attack) | 429 |
| Anything unexpected | 500, logged with `request_id`, `api.request_rejected` audit; generic body — internals never leak |

### 7.4 Jobs: retry what's transient, record what's terminal, never lose a run

```ruby
class ApplicationJob < ActiveJob::Base
  # Sidekiq adapter. Queues: ingestion / layers / finalize (config/sidekiq.yml).
  retry_on Errors::ProviderUnavailable, wait: :polynomially_longer, attempts: 4
  # Backstop for record-not-yet-visible edges (we enqueue after commit, but this
  # guards operator mistakes and replicas): brief retries, then audit + drop.
  retry_on ActiveJob::DeserializationError, wait: 2.seconds, attempts: 3 do |job, error|
    Audit::Recorder.record!("layer.errored", payload: { job: job.class.name, error: error.class.name })
  end
end
```

- `VerificationLayerJob` wraps processor execution; on final retry exhaustion it
  marks the LayerResult `errored` (class+message persisted, `panel_verdict:
  "warn"`, detail "layer unavailable") **and still triggers the completion check**
  — a dead provider can never strand a run in `running` forever.
- **Enqueue-after-commit, always.** Sidekiq's queue is a separate datastore:
  enqueueing inside a DB transaction lets a worker execute before the rows are
  committed. Ingestion collects job args and enqueues only after the transaction
  returns (§8).
- **Redis down must not lose a lead.** Enqueue calls are wrapped: on
  `Redis::CannotConnectError` (and kin) the lead + run stay `pending`, a
  `system.enqueue_failed` audit event is recorded (recorder is DB-only, so it
  still works), the API still returns 201, and the run is recoverable via the
  dashboard "re-verify" action / a `verification:requeue_stuck` rake task. Tested
  in chunk 6.3.
- Broadcast failures are rescued and logged — realtime is best-effort; the DB row
  is the truth (a reconnecting/polling client can re-read state).
- Every job is idempotent (§9) — safe under Sidekiq's at-least-once delivery.
- Sidekiq Web is mounted at `/admin/sidekiq` behind a super_admin-only
  authenticate constraint — never unauthenticated.

### 7.5 Fail-open vs fail-closed — deliberate, per layer (design question #5)

From `layer_definitions.criticality`:

| Layer | Criticality | If errored/unavailable |
|---|---|---|
| trustedform, dnc, blacklist_alliance, duplicate_detection | **required** | **Fail closed**: verdict capped at REVIEW; reason "required layer unavailable: X". Consent/compliance gaps are never auto-ACCEPTed, but we don't destroy a possibly-good lead either. |
| anura, vpn_proxy, phone/email validation, enrichment, voice | optional | **Fail open**: proceed, 0 score delta, certificate records `errored` — visible, never counted as "pass". |

Certificates always distinguish `not_enabled` / `not_applicable` / `errored` /
`completed` — an unavailable layer is **never** presented as a passed check.

### 7.6 Client-side (pixel) resilience

The pixel must never break the buyer's page or funnel: everything wrapped;
listener exceptions isolated (as in the reference snippet); network failures
degrade to silence; WS reconnect with capped backoff (5 attempts) then fall back
to 3s polling of `GET /api/pixel/leads/:id/activity`; the form always submits.

### 7.7 DB as last line of defense

CHECK (`credit_balance >= 0`), unique indexes under every idempotency rule
(lead replay, layer per run, ledger entry per run+type, cert per run, verdict per
run, cert sequence per account), FK constraints everywhere, string enums
validated at both layers. If application code has a bug, Postgres refuses the
corruption.

---

## 8. Ingestion — one transaction, then fan out

`POST /api/pixel/leads` → `Leads::IngestionService`, all inside a single
transaction:

1. Authenticate pixel (public key → pixel → **account**; tenant set from the
   pixel, *never* from the payload — a payload `account_id` is ignored: this is
   the cross-account-write defense).
2. Enforce Origin against `allowed_domains`; enforce replay via unique
   `(pixel_id, session_id)` (hit → return original lead, 200, audit).
3. Normalize email/phone (E.164-ish digits; lowercase email — homoglyphs like
   L-1008's Cyrillic `о` are preserved as-is and matched exactly; detection is the
   email provider's job).
4. Create Lead (+ link Visit by `session_id` → visit IP vs submit IP available
   server-side).
5. **Reserve credits** (§10). Insufficient → lead saved with status
   `on_hold_insufficient_credits`, audit `credits.insufficient` + `lead.on_hold`,
   respond 402 with a clear message; nothing else runs. (Answers "zero credits":
   we never start work we can't bill; the lead is retained and re-runnable after
   top-up via a dashboard button.)
6. Create VerificationRun + **pre-create all 10 LayerResult rows**:
   - not in account modules ∩ pixel layers → `not_enabled` (final immediately)
   - enabled → `pending`
7. Audit: `lead.received`, `verification.started`, `credits.reserved`.
8. **After the transaction commits** — never inside it — enqueue
   `VerificationLayerJob` per enabled layer (Sidekiq lives in Redis; an in-
   transaction enqueue can run before the lead row exists). Enqueue failures
   follow the Redis-down rule in §7.4: lead kept, run `pending`, audited,
   recoverable.
9. Respond `201 { lead_id, stream_token, channel: "VerificationChannel" }` —
   note: the reference pixel expects `lead_id` in the response (CLAUDE_1.md
   returned `correlation_id` — contract mismatch, fixed).

Pre-creating rows makes the three rubric states first-class from t0, gives the
panel skeleton rows, and turns job idempotency into a row-level CAS (§9).

---

## 9. Layer pipeline — parallel, idempotent, race-free

**Processors** (`app/services/layers/*_processor.rb`, one per key, shared
`BaseProcessor` contract): read the lead + gateway payload → return
`{status, verdict, panel_verdict, detail, score_delta, raw_response}`.
All ten implemented — **including voice**: `has_sample: false → not_applicable`;
with a sample it returns real verdicts (`human_reused_actor` on L-1009 is a heavy
fraud signal; CLAUDE_1.md stubbing voice as always-not_applicable was wrong and
would miss a seeded scenario).

**Providers::Gateway** — the vendor-call seam (swap for HTTP clients later):
1. Look up `provider_responses` by `(layer_key, lead_ref)` for seeded leads;
2. else by normalized phone/email — so typing a seed persona (e.g. Robert
   Vance's phone) into the live demo form replays that scenario end-to-end;
3. else a **deterministic clean default** per layer — a brand-new demo lead gets
   `verified`/`clean`/`good` responses and ACCEPTs instead of erroring on every
   layer (CLAUDE_1.md errored on unknown identities → live demo would show 10
   failures — the exact "red flag" demo the rubric warns about).
4. Configurable simulated latency (250–900ms deterministic per layer; 0 in test)
   so the panel visibly trickles like the simulation did.

**VerificationLayerJob(run_id, layer_key)** — idempotent by CAS:

```ruby
# claim: only one worker can move pending → processing
claimed = LayerResult.where(id: row.id, status: %w[pending processing])
                     .update_all(status: "processing", started_at: Time.current)
return if claimed.zero? && row.reload.terminal?   # retry after success = no-op
```

Persist outcome → `layer.completed` / `layer.errored` audit (broadcast rides on
the audit write) → completion check.

**Finalization — the race CLAUDE_1.md ships:** two last jobs finishing together
both count results, both run consensus → duplicate certificate + double credit
movement. Fix is an atomic compare-and-set; exactly one winner enqueues the
finalizer:

```ruby
def maybe_finalize(run)
  return if run.layer_results.where(status: %w[pending processing]).exists?
  won = VerificationRun.where(id: run.id, status: "running")
                       .update_all(status: "finalizing", updated_at: Time.current)
  FinalizeRunJob.perform_later(run.id) if won == 1
end
```

`FinalizeRunJob` (idempotent: unique indexes on verdict/cert + ledger entry-type
make a retry harmless): consensus → verdict → certificate → settlement → run
`completed` → lead denormalized (`status`, `verdict`, `flags`) → ACCEPTed leads
appended to `crm_records` (future duplicates are caught) → `final_verdict`
broadcast `{ verdict, score: score/100.0, reasons }` (page multiplies by 100).

---

## 10. Credits — reserve → settle, ledger is the truth

Answering design Q9 with the fixtures' own semantics (`module_costs_in_credits`
exists — flat 1/run ignores the data):

- **Reserve at ingestion**: `Σ cost(enabled layers)` (17/21/8 per account, verified
  §4) deducted up front inside the ingestion transaction with `account.lock!`,
  ledger `reservation` entry with per-layer `breakdown`, `balance_after` snapshot.
- **Settle at finalization**: refund cost of layers that ended `not_applicable` or
  `errored` (we don't bill checks that didn't run) — `settlement_refund` entry.
- **Zero mid-verification is impossible by construction** — the run was funded at
  start (CLAUDE_1.md deducted *after* completion and swallowed the failure —
  free verifications on a broke account). Insufficient at ingestion → §8.5 hold.
- `credit_balance` is a cached projection; invariant **`balance == Σ(ledger)`**
  is asserted by a test and a `bin/rails credits:audit` task. CHECK ≥ 0.
- Unique `(verification_run_id, entry_type)` → retried finalizer can't
  double-refund; reservation inside the unique-guarded ingestion can't repeat.
- **Burn rate** = trailing 7-day ledger sum (fixture `avg_daily_burn` as seeded
  fallback for empty history); **days-to-zero** = balance / burn. Super-admin
  flags: `past_due` badge, days-to-zero < 1 (acct_autoinsure trips both), plus
  `account.flagged_low_credits` audit event when a settlement crosses the
  threshold — the dashboard warning has a queryable trail.

Seed balance math (so post-seed balances equal `accounts.json` exactly while the
ledger stays sum-consistent): grant `monthly_credit_allowance`, insert an
`adjustment` of `-(credits_used_this_cycle − Σ seeded-run settled costs)` memo
"prior cycle usage (aggregate)", then let the 12 seeded runs spend through the
real reserve/settle path.

---

## 11. Consensus engine — policy-driven, calibrated, explainable

`Consensus::Engine.call(run)` → `{verdict, score, reasons[], flags[],
hard_stop_layer, policy_snapshot}`.

**Resolution order:**
1. Build `Consensus::Policy` = layer_definitions defaults ⊕ account
   `layer_policies` overrides (weights, hard-stop promotions) ⊕ account threshold
   overrides (`settings`). Snapshot it onto the verdict row — every verdict is
   auditable against the exact policy that produced it (design Q6: policy is
   **data**; a buyer promotes `blacklist_alliance: suspected` to a hard stop by
   flipping `treat_as_hard_stop`, no deploy).
2. **Hard stops** (first match REJECTs, score forced 0, reason names the layer):

   | Layer | Hard-stop condition |
   |---|---|
   | blacklist_alliance | `status == "litigator"` (suspected is weighted, promotable) |
   | dnc | `dnc_status ∈ {dnc_listed, internal_dnc}` ("can't call it, don't buy it") |
   | trustedform | `status ∈ {mismatch, not_found, expired}` — consent can't be proven |
   | anura | `result == "bad"` (bot/malware) |
   | duplicate_detection | exact duplicate (phone AND email match in account CRM) → verdict REJECT, flag `duplicate`, reason cites the CRM record (renders as "REJECT — duplicate", covering the `REJECT_DUPLICATE` hint) |

3. **Weighted scoring** from 100, only over layers that `completed`;
   `not_enabled`/`not_applicable` contribute nothing (never penalize a lead for a
   module the buyer didn't buy). Defaults (seeded into `layer_definitions`,
   calibrated so all 12 fixtures derive correctly through *their account's
   enabled layers only*):

   | Signal | Δ |
   |---|---|
   | anura suspect, unclassified | −15 |
   | anura suspect + `anonymizer` | −35 |
   | anura suspect + `human_fraud_farm` | −50 |
   | vpn/proxy/tor detected | −25 (+−10 if visit-IP ≠ submit-IP) |
   | vpn risk medium, clean | −5 |
   | phone: providers disagree on validity | −20 |
   | phone: consensus valid but all VoIP | −15 (agreement on VoIP ≠ disagreement — L-1009 vs L-1007 differ exactly here) |
   | phone: consensus invalid (≥2 invalid) | −30 |
   | phone: line-type split, all valid | −5 |
   | email: both undeliverable | −35 |
   | email: providers split | −15 |
   | email: disposable (agreed) | −25 |
   | enrichment: sources disagree / single-source | −12 |
   | enrichment: no match to lead (both) | −20 |
   | blacklist suspected | −25 |
   | voice `human_reused_actor` / `synthetic` | −50 |
   | soft duplicate (same phone, diff email, recent) | −10 + flag `soft_duplicate` — surfaced for humans, never auto-reject (L-1012 stays ACCEPT) |

4. **Bands**: `score ≥ 70 → ACCEPT`, `40–69 → REVIEW`, `< 40 → REJECT`
   (thresholds account-overridable).
5. **Reasons**: ordered human strings per contributing signal (+ "all enabled
   layers passed" when clean); flags carried to lead, certificate, and panel.

**Cross-check vs the 12 (engine stays generic; this table lives in the harness
spec, not app code):** L-1001 100 A · L-1002 anura-bad stop R · L-1003 −35 → 65
REVIEW · L-1004 dup stop · L-1005 DNC stop (litigator layer not owned!) · L-1006
DNC stop · L-1007 −15−20 → 65 REVIEW · L-1008 −35 → 65 REVIEW · L-1009 −50−15 →
35 REJECT · L-1010 TF stop · L-1011 −25−12−5 → 58 REVIEW · L-1012 −10 → 90
ACCEPT + flag. The duplicate layer treats "recent" as |lead.submitted_at −
crm.source_created_at| ≤ 30 days — absolute difference, because the L-1012 CRM
fixture is dated *after* the lead's capture (fixture quirk, handled not ignored).

**Unavailability** feeds §7.5 (required-layer error ⇒ cap at REVIEW with reason).

---

## 12. Consent certificates — canonical hash + per-account chain

Evidence jsonb: lead identity snapshot, pixel/page/session context, visit-vs-submit
IPs, **full per-layer table (all 10 keys with status — the three states are
explicit in the certificate)**, verdict + score + reasons + flags, policy_snapshot,
TrustedForm reference + its match/expiry fields, timestamps, engine version.

**Hashing bug fixed from CLAUDE_1.md:** `jsonb` does not preserve key order —
hashing `evidence.to_json` at issuance and re-hashing after a Postgres round-trip
mismatches. All hashing goes through canonical JSON:

```ruby
module Certificates
  module CanonicalJson
    def self.generate(obj) = JSON.generate(sort(obj))
    def self.sort(o)
      case o
      when Hash  then o.keys.sort.each_with_object({}) { |k, h| h[k] = sort(o[k]) }
      when Array then o.map { |v| sort(v) }
      else o
      end
    end
  end
end
# evidence_hash = SHA256(CanonicalJson.generate(evidence))
```

Chain: `previous_hash` = prior certificate's hash for the account (advisory lock
on account during issuance; `sequence_number` unique per account) — mutating any
historical certificate breaks every later link, not just its own hash.

Surfaces: dashboard cert page (auth, tenant-scoped) · **public verifier**
`GET /verify/:public_id` (+ `.json`) — recomputes the hash from stored evidence
and renders VALID / TAMPERED with the evidence table · immutability = readonly
model + no update routes + append-only convention documented.

---

## 13. Multi-tenancy, authorization, pixel security

- `acts_as_tenant :account` on every tenant model; `require_tenant = true` (not
  CLAUDE_1.md's `false` — unscoped-by-default is how leaks ship). Super-admin
  controllers opt out *explicitly* per action via `ActsAsTenant.without_tenant`;
  jobs run inside `ActsAsTenant.with_tenant(run.account)`.
- Controllers still load through associations (`current_account.leads.find …`) —
  isolation holds even if the gem is misconfigured; request specs prove A→B is 404
  for leads, pixels, certificates, and audit events, by direct id.
- Pundit on top for roles: member read-only; account_admin manages pixels/users/
  policies; super_admin platform-wide read (+ account status flags). Policy specs
  enumerate the matrix. Super-admin power containment (design Q8): separate
  `Admin::` namespace + explicit `without_tenant` blocks + every admin action
  audited (`policy.updated`, `pixel.updated`, …).
- **Pixel API**: public key identifies pixel→account (server-side binding; payload
  can't choose a tenant) · Origin/Referer vs `allowed_domains` (seeds include
  `localhost:3000` for the demo) · replay = unique `(pixel_id, session_id)` ·
  rack-attack per key+IP · **rack-cors** scoped to `/api/pixel/*` (the pixel is
  cross-origin by definition; CLAUDE_1.md had no CORS — every real embed would
  die in preflight).
- **Stream auth**: the 201 response includes a `stream_token` =
  `Rails.application.message_verifier(:pixel_stream).generate({lead_id:, exp: 15.min})`;
  `VerificationChannel` rejects without a valid token — client-generated session
  ids are guessable, so nobody can subscribe to another lead's activity
  (pixel-spec security question, answered concretely).

What lives client-side (public by definition): pixel public key, page context,
form field values the visitor typed. Everything else — account binding, module
list, credits, verdicts, evidence — is server-side only.

---

## 14. Real-time — ActionCable (Redis adapter), and why

Chosen over SSE/polling: bidirectional isn't needed, but Cable gives Rails-native
channel auth, reconnection, and one transport shared by the pixel panel **and**
Turbo Streams on the CRM (same broadcast, two consumers). Trade-off documented:
connection cost per visitor vs SSE's simplicity; polling fallback exists anyway
(§7.6). Redis is already present for Sidekiq, so the Cable adapter adds zero new
infrastructure (`async` adapter in test).

- `Realtime::Broadcaster.publish(event)` maps AuditEvents → the exact wire shapes
  the landing page already consumes (`layer_result {layer, verdict:
  pass|warn|fail|skip, detail}`, `final_verdict {verdict, score(0..1), reasons}`),
  plus `info` rows for lifecycle moments ("credits reserved (17)", "certificate
  cert_… issued"). One source of truth: the panel is literally a rendering of the
  audit stream.
- **Production `super-pixel.js`** (served by us; generated snippet =
  `<script async src=".../super-pixel.js" data-pixel-id="px_…" data-endpoint=".../api/pixel">`):
  same public API (`onActivity`, `attach`, auto-attach on `data-pixel-form`) so
  the example page works unmodified; real `/visit` + `/leads` posts; subscribes
  via a ~40-line dependency-free ActionCable wire-protocol client (subscribe
  command + ping handling + backoff reconnect) — no bundler, no CDN.
- `/demo` — the assignment's landing page served by the app, snippet swapped to a
  seeded SolarPro pixel, plus a **scenario cheat-sheet panel**: the 12 personas'
  names/emails/phones. Type Robert Vance's phone → watch a DNC hard-stop live;
  unknown identities → clean defaults → ACCEPT (§9 gateway). Simulation code path
  never loads. **`image.png` at the repo root is the visual reference** (the
  target page in idle state): keep its two-column card layout and dark live-
  activity panel exactly — we rewire the page to real events, we do not restyle
  it.

---

## 15. Dashboards (clean > pretty; Turbo-live where it's free)

- **CRM** (`/app/leads`): filter by verdict/status/flag/date + search on
  normalized email/phone/name (indexed), Pagy. Row → verdict chip, score, flags.
  Detail: per-layer table (all 10 with three-state rendering + detail + timing),
  reasons, certificate link, **activity timeline** (audit events §6). Turbo
  Stream prepend on new leads/verdicts.
- **Pixels**: CRUD (admin-only writes), allowed domains, enabled layers
  (checkboxes limited to account modules), copy-paste snippet block, per-pixel
  cost/run readout.
- **Audit explorer** (`/app/audit`): filterable event stream (type, subject,
  date). Same component powers `/admin/audit` unscoped.
- **Review queue**: CRM filtered to REVIEW — the human loop the verdict implies.
- **Super-admin** (`/admin`): accounts table (plan, status w/ `past_due` badge,
  balance, allowance-used %, ledger burn rate, projected days-to-zero,
  low-credit/past-due flags — acct_autoinsure lights up), platform verdict split,
  recent platform audit events, account drill-down (read-only + its ledger).

---

## 16. Seeds — idempotent, engine-derived, self-verifying

Order: layer_definitions (registry + `module_costs_in_credits`) → accounts (+
grant & prior-usage adjustment per §10) → users (placeholder passwords from
`users.json`, bcrypt; table printed at end) → pixels (fixture `px_…` ids;
localhost + fixture domains allowed) → layer_policies (from `enabled_modules`) →
provider_responses (all 9 files, `_comment`/`_note` stripped) → crm_records →
**leads**: ingest through the real `IngestionService`, then run the pipeline
**synchronously in-process** (`perform_now` per layer + finalizer — seeding must
never depend on a running Sidekiq worker or race against one), gateway latency 0.
`expected_verdict` is **stripped on import** — it exists only in the seed report
and the harness spec.

`db:seed` ends by printing: derived vs hint verdict table for all 12 (with
reasons), post-seed credit balances vs `accounts.json` (must match exactly), and
login credentials. Idempotent via `find_or_initialize_by(public_id:)` — safe to
re-run.

---

## 17. Testing strategy (highest-value first)

1. **Consensus engine** (pure unit, no DB where possible): every hard stop; band
   edges (39/40/69/70); policy overrides (weight + hard-stop promotion + custom
   thresholds); not_enabled/not_applicable excluded from scoring; required-layer
   error → REVIEW cap; optional-layer error → fail-open.
2. **The 12-lead harness**: seed fixtures → real pipeline inline → assert derived
   verdict per lead + key reasons/flags (soft_duplicate on L-1012, duplicate flag
   on L-1004, DNC-not-litigator hard stop on L-1005). This is the regression net
   proving "defensible against the seeds, not hardcoded".
3. **Tenant isolation** (request specs): user A vs account B's lead / pixel /
   certificate / audit trail → 404 by direct id; super_admin sees both; member
   cannot mutate pixels (403).
4. **Pixel API**: bad key 401; disallowed origin 403; replay returns same lead
   200 + audit; payload account spoof ignored; happy path creates the full row
   set (10 layer rows in correct initial states) + reservation.
5. **Credits**: reservation math per account module set (17/21/8); refund on
   not_applicable/errored; hold path at insufficient; `balance == Σ ledger`
   invariant; concurrent deduction under threads (row lock holds); ledger
   entry-type uniqueness under a retried finalizer.
6. **Idempotency & races**: LayerJob run twice → one terminal row, one audit
   trail, no duplicate broadcast; `maybe_finalize` raced from two threads → one
   verdict, one certificate, one settlement.
7. **Certificates**: canonical hash stable across jsonb round-trip (regression
   for the key-order bug); verifier flags mutated evidence; chain breaks
   downstream links; sequence gapless per account.
8. **Audit**: recorder captures actor/request_id/account; append-only (update
   raises); each pipeline stage emits its expected event types (spec asserts the
   taxonomy for one full run).
9. **System specs (2)**: login → CRM shows seeded verdicts; demo page submit →
   panel rows appear → final verdict rendered (Cable in test via async adapter).

Factories mirror fixture shapes. CI-grade `bin/ci`: rubocop (rails-omakase) +
brakeman + rspec.

---

## 18. Folder structure

```
app/
├── channels/verification_channel.rb
├── controllers/
│   ├── application_controller.rb            # devise auth, Current, tenant, rescue map
│   ├── demo_controller.rb                   # /demo landing page
│   ├── verifications_controller.rb          # public /verify/:public_id
│   ├── api/pixel/
│   │   ├── base_controller.rb               # key auth, origin, CORS, envelope
│   │   ├── visits_controller.rb             # POST /api/pixel/visit
│   │   ├── leads_controller.rb              # POST /api/pixel/leads
│   │   └── activities_controller.rb         # GET  …/leads/:id/activity (poll fallback)
│   ├── app/                                 # account dashboard namespace
│   │   ├── base_controller.rb
│   │   ├── leads_controller.rb, pixels_controller.rb,
│   │   ├── certificates_controller.rb, audit_events_controller.rb
│   │   └── credits_controller.rb            # ledger view + balance
│   └── admin/                               # super_admin (explicit without_tenant)
│       ├── base_controller.rb, dashboard_controller.rb
│       ├── accounts_controller.rb, audit_events_controller.rb
├── jobs/
│   ├── application_job.rb                   # retry/discard policy (§7.4)
│   ├── verification_layer_job.rb
│   └── finalize_run_job.rb
├── models/                                  # + current.rb; associations/validations/
│   └── …                                    #   scopes only — no business logic
├── policies/                                # pundit (application/lead/pixel/…)
├── services/
│   ├── application_service.rb               # shared Result (§7.2)
│   ├── audit/recorder.rb  · audit/events.rb # taxonomy constants
│   ├── leads/ingestion_service.rb · leads/normalizer.rb
│   ├── verification/run_creator.rb · verification/finalizer.rb
│   ├── layers/base_processor.rb · layers/<10 processors>.rb · layers/registry.rb
│   ├── providers/gateway.rb
│   ├── consensus/engine.rb · policy.rb · hard_stop_evaluator.rb
│   │   · signal_scorer.rb · reason_builder.rb
│   ├── certificates/issuer.rb · verifier.rb · canonical_json.rb
│   ├── credits/reservation.rb · settlement.rb · burn_rate.rb
│   ├── pixels/snippet_generator.rb
│   └── realtime/broadcaster.rb
├── views/  layouts/ · devise/sessions/ · demo/ · verifications/ · app/{leads,
│           pixels,certificates,audit_events,credits}/ ·
│           admin/{dashboard,accounts,audit_events}/
└── javascript/                              # Stimulus for dashboard niceties
public/super-pixel.js                        # production pixel (served as-is)
Procfile.dev                                 # web · css · sidekiq
config/sidekiq.yml                           # queues: ingestion, layers, finalize
config/cable.yml                             # redis adapter (async in test)
config/initializers/ devise.rb · sidekiq.rb · acts_as_tenant.rb · cors.rb
                     · rack_attack.rb
db/ migrate/ · seeds.rb · seeds/{layer_definitions,accounts,users,pixels,
    policies,provider_responses,crm_records,leads}.rb
spec/ factories/ · models/ · services/{consensus,credits,certificates,layers,leads}/
      · requests/{api,app,admin}/ · jobs/ · system/ · seeds/harness_spec.rb · support/
```

### 18.1 Engineering standards — non-negotiable rules

#### Design principles (SOLID, applied — not recited)

- **SRP — the "and" test.** Every class does exactly one thing; if describing it
  needs the word "and", split it. This is already encoded in the tree: a
  processor evaluates *one* layer; `Providers::Gateway` only *fetches* provider
  data; `Consensus::Engine` only *decides* (it persists nothing — the Finalizer
  does); `Audit::Recorder` only *writes events*; `Certificates::Issuer` only
  *issues*. New code must keep that separation — a service that fetches AND
  decides AND persists is three services.
- **One level of abstraction per method.** Methods ≤ ~10 lines; a method either
  orchestrates named steps or does one step — never both. Extract to
  intention-revealing private methods the moment levels mix.
- **Small classes.** A service over ~100 lines is hiding a second responsibility.
- **Dependency direction is one-way:** controllers → services → models.
  Services never know about HTTP/params/rendering; models never call services;
  jobs are thin delivery shells that set context and delegate to a service.
- **Composition over inheritance.** Inheritance only for a true is-a within one
  namespace (`Layers::BaseProcessor`, `ApplicationService`, controllers/jobs).
- **Don't reach through objects.** No `run.lead.pixel.account.settings` train
  wrecks inside services — pass what's needed as keyword arguments; the caller
  owns navigation.
- **Guard clauses over nesting.** Early returns; maximum nesting depth 2.
- **No magic values.** Named frozen constants for anything used twice or
  unobvious once; tunable policy (weights, thresholds, costs) lives in the DB
  (§11), never as inline literals in logic.
- **Fail fast at boundaries.** Programmer misuse raises `ArgumentError`
  immediately; expected domain outcomes return Result failures (§7.2). Never
  let a nil limp three calls away from its cause.
- **YAGNI / KISS.** Build exactly what a §section specifies — no speculative
  abstractions, options, or "flexibility" nobody asked for.
- **DRY with judgement.** Extract on the third occurrence; duplication is
  cheaper than the wrong abstraction.
- **Idempotency by default.** Any service/job that mutates must be safe to call
  twice (§9 patterns: CAS, unique indexes, find-or-create).

#### Naming — meaningful, searchable, Rails-conventional

- Names reveal intent and are searchable. Banned: abbreviations (`vrun`, `le`,
  `cfg`), vague nouns (`data`, `info`, `Manager`, `Helper`, `Util`, `Misc`),
  vague verbs (`process`, `handle`, `do_stuff`). `verification_run`, not `vr`.
- Models singular (`Lead`); controllers plural (`LeadsController`); jobs end in
  `Job`; policies in `Policy`; services are namespaced role nouns named for the
  one thing they do (`Leads::IngestionService`, `Credits::Reservation`,
  `Certificates::Issuer`) with a single public method: `call`.
- Predicates end in `?` and return booleans; bang methods only where a raising
  variant of a safe method exists (AR convention). Booleans read as assertions
  (`enabled`, `hard_stop_capable`) — never negated names (`not_valid`,
  `disabled_flag`).
- DB: tables plural snake_case; foreign keys `_id`; timestamps `_at`; enums are
  strings whose values equal the Ruby symbols exactly; layer keys come ONLY from
  the §4 canonical list; audit event names ONLY from `Audit::Events` constants.
- Constants `SCREAMING_SNAKE_CASE` and frozen. No single-letter variables
  except a counter in a trivial loop; block args are full words
  (`.map { |lead| … }`).
- Spec names describe behavior: `"rejects when a confirmed litigator is found"`
  — never `"works"`, `"test1"`, `"happy path"`.
- The same care applies to `super-pixel.js`: real function names, no
  one-letter variables, module-scoped — nothing leaks globally except
  `window.SuperPixel`.

#### Rails rules

- **Migrations:** `null: false` unless genuinely optional; defaults in the DB,
  not only in Ruby; every FK gets an index AND a constraint; every
  WHERE/ORDER-BY column indexed; CHECK constraints for invariants; no
  `default_scope`. (`algorithm: :concurrently` is a production-on-populated-
  tables habit — pointless in these greenfield migrations; know the difference,
  say so if asked.)
- **Models:** associations (always with an explicit `dependent:` decision),
  validations, string enums, named scopes — nothing else. Callbacks only for
  data normalization (`before_validation :normalize_email`); never for side
  effects (no jobs, mails, audits, or broadcasts from callbacks).
- **Controllers:** authenticate/authorize/set-context in ≤3 before_actions; one
  service or one scoped query per action; strong params always
  (`params.expect`); correct status codes; zero query-building (scopes own
  `.where`).
- **Views:** no queries (controllers preload with `includes` — an N+1 in a list
  view is a defect, not a nitpick); partials for repetition; helpers format,
  never decide.
- **Jobs:** deserialize → set tenant + `Current` → delegate to one service.
  Retry/discard policy lives in `ApplicationJob` only (§7.4).
- **Queries:** `exists?` over `present?` on relations; `find_each` for batches;
  `update_all`/`insert_all` only at the documented CAS/idempotency points
  (§9) with a comment stating why callbacks/validations are intentionally
  skipped there.
- **Time:** `Time.current` / `Time.zone`, never `Time.now` / `Date.today`;
  everything stored UTC.
- **Security:** no `html_safe` on user input; no SQL string interpolation —
  bind params/hash conditions only; secrets in credentials/ENV, never in git;
  `brakeman` stays at zero warnings.
- **Style:** `# frozen_string_literal: true` everywhere; rubocop-rails-omakase
  is the arbiter — zero offenses; `rubocop:disable` requires an inline reason
  and the narrowest possible scope.
- **Comments** state *why* or a non-obvious constraint — never *what* the next
  line does, never journal entries. i18n is deliberately skipped (single-locale
  take-home; noted in SOLUTION.md).

---

## 19. Routes

```ruby
devise_for :users                            # sessions only; registerable off
authenticated :user do
  root "app/leads#index", as: :authenticated_root
end
root to: redirect("/users/sign_in")

get  "demo",              to: "demo#show"
get  "verify/:public_id", to: "verifications#show", as: :verify_certificate

namespace :api do
  namespace :pixel do
    post "visit", to: "visits#create"
    resources :leads, only: :create do
      get :activity, on: :member            # polling fallback
    end
  end
end

namespace :app do                            # account dashboard
  root "leads#index"
  resources :leads, only: %i[index show] do
    post :reverify, on: :member              # after credit top-up
  end
  resources :pixels
  resources :certificates,  only: %i[index show]
  resources :audit_events,  only: :index
  resource  :credits, only: :show, controller: "credits"
end

namespace :admin do                          # super_admin
  root "dashboard#index"
  resources :accounts,     only: %i[index show]
  resources :audit_events, only: :index
end

authenticate :user, ->(u) { u.super_admin? } do
  mount Sidekiq::Web => "/admin/sidekiq"     # never unauthenticated
end
```

---

## 20. Build order — execution contract + chunk list

### 20.0 Execution contract (STRICT — this is how "nothing gets missed")

1. **Work the chunks below in order, one at a time.** A chunk is *done* only when
   its **Done when** holds **and** `bin/ci` (rubocop + brakeman + full rspec) is
   green. One commit per chunk, message prefixed with the chunk id
   (`[2.5] pixel leads endpoint: transactional ingestion`).
2. **Never skip, never half-do.** If a chunk turns out bigger than expected,
   split it into sub-chunks and finish them all — do not "come back later".
   Later never comes.
3. **Forbidden in delivered code:** `TODO` / `FIXME` / `HACK` / `XXX` comments;
   `raise NotImplementedError` (sole exception: `Layers::BaseProcessor#call`
   contract); empty `rescue` blocks; commented-out code; placeholder views or
   "coming soon" screens; routes/actions with no view or no spec; `binding.irb`
   / `byebug` / stray `puts` / `console.log`. Chunk 6.6 greps for all of these.
4. **Stubs are allowed only where the assignment allows them** (vendor calls =
   seeded Gateway, email delivery, payments) — each one named in `SOLUTION.md`.
   Anything else that feels like it needs a stub is a design problem: stop and
   fix the design.
5. **Blocked ≠ skipped.** If a chunk genuinely cannot be completed, stop and
   surface the blocker explicitly (in the session and in a `BLOCKERS` note in
   the commit); do not silently route around it or drop the scope.
6. **Every phase ends with its gate** (listed per phase). Do not enter the next
   phase with a red or partially-run gate.
7. **Scope cuts are decisions, not omissions.** If the timebox forces cuts, cut
   only whole chunks from the allowed-cut list (bottom of §20.7), record each
   cut + reason in `SOLUTION.md`. Cutting anything else is failure, not triage.
8. **Definition of done for the whole build** = chunk 6.6's completeness audit
   passing on a fresh clone. Not before.

### 20.1 Phase 0 — Skeleton (Day 1 morning)

- **0.1 App + gems.** `rails new` (PG); Gemfile: devise, sidekiq, redis,
  acts_as_tenant, pundit, rack-cors, rack-attack, pagy, tailwindcss-rails,
  turbo/stimulus, rspec-rails, factory_bot_rails, capybara, brakeman,
  rubocop-rails-omakase. `bin/setup` (checks PG **and** Redis, fails with
  instructions), `Procfile.dev` (web/css/sidekiq), `bin/ci` script.
  *Done when:* `bin/dev` boots, `/up` → 200, `bin/ci` green on empty suite.
- **0.2 Sidekiq + Cable wiring.** ActiveJob adapter :sidekiq; `config/sidekiq.yml`
  (queues: ingestion, layers, finalize, default); initializer; `cable.yml` redis
  (async in test). *Done when:* a smoke job round-trips through Redis in dev;
  job spec runs inline in test.
- **0.3 Test harness.** RSpec config, FactoryBot, Capybara + system-spec driver,
  Devise test helpers placeholder, ActiveJob/test adapters, spec/support layout.
  *Done when:* one model spec + one request spec + one system spec (trivial)
  all pass.

**Phase 0 gate:** `bin/ci` green; `bin/dev` serves a page; Sidekiq dashboardable.

### 20.2 Phase 1 — Foundation: schema, auth, tenancy, audit, errors (Day 1)

- **1.1 Migrations A (identity/config):** accounts, users (Devise cols + role +
  account_id), pixels, layer_definitions, layer_policies — every column,
  default, CHECK, and index from §5. *Done when:* schema matches §5 verbatim;
  model validations + enums + association specs pass.
- **1.2 Migrations B (pipeline):** visits, leads, verification_runs,
  layer_results incl. all unique indexes (replay, one-layer-per-run).
  *Done when:* same bar as 1.1.
- **1.3 Migrations C (outcomes/money/audit):** consensus_verdicts,
  consent_certificates (no updated_at), credit_ledger_entries (no updated_at,
  entry-type unique), audit_events (all five indexes + GIN), crm_records,
  provider_responses; CHECK `credit_balance >= 0`. *Done when:* full §5 schema
  exists; `db:migrate:status` clean; zero pending model specs.
- **1.4 Devise auth.** Install; User modules per §2 (registerable OFF); role
  enum + account presence/absence validations; styled sign-in view; rack-attack
  login throttle; Sidekiq::Web mounted behind super_admin constraint.
  *Done when:* request specs: login ok / wrong password / throttle 429; only
  super_admin reaches /admin/sidekiq (others 404/redirect).
- **1.5 Current + tenancy.** `Current` attrs; `acts_as_tenant` on every tenant
  model; `require_tenant = true`; ApplicationController sets tenant + Current;
  Admin::BaseController with explicit `without_tenant`; job tenant wrapper.
  *Done when:* model-level scoping spec (Lead.all under tenant A never returns
  B) + require_tenant raises without tenant.
- **1.6 Pundit.** ApplicationPolicy default-deny; policies for lead, pixel,
  certificate, audit_event, account, credits; full role×action matrix specs.
  *Done when:* matrix specs pass; unauthorized web hits render friendly 403.
- **1.7 Audit spine.** `Audit::Events` frozen constants (§6 taxonomy);
  AuditEvent readonly model; `Audit::Recorder` (+ no-op `Realtime::Broadcaster`
  shell whose full impl lands in 4.1 — shell logs only, documented); Warden
  hooks → auth.login_succeeded/failed/logout events.
  *Done when:* recorder specs (context capture, append-only update raises,
  local-env raise on failure, prod swallow+log); login writes events.
- **1.8 Error framework.** `Errors` taxonomy; ApplicationService + shared
  Result; HTML rescue map; `Api::Pixel::BaseController` JSON envelope +
  rescue map (§7.3 table); ApplicationJob retry/discard policy (§7.4).
  *Done when:* anonymous-controller specs prove every envelope row of §7.3.
- **1.9 Seeds A (static).** layer_definitions (registry + costs + criticality +
  §11 default weights); accounts (+ allowance grant ledger entries; reconciling
  adjustment lands in 3.6); users (fixture placeholder passwords via Devise);
  pixels (fixture `px_…`, allowed_domains incl. localhost); layer_policies from
  `enabled_modules`. Idempotent. *Done when:* `db:seed` twice → zero duplicates;
  seeded logins work; per-account cost/run computes 17/21/8 in a spec.

**Phase 1 gate:** `bin/ci` green; isolation + policy + audit + envelope specs
all in place; fresh `db:reset db:seed` clean.

### 20.3 Phase 2 — Ingestion & layer pipeline (Day 2)

- **2.1 Edge protection.** rack-cors for `/api/pixel/*`; rack-attack throttles
  (pixel key + IP) with `api.throttled` audit; request-id middleware → Current.
  *Done when:* preflight spec passes; 61st request in window → 429 + audit row.
- **2.2 Visit beacon.** Pixel auth in base controller (public key → pixel →
  tenant; payload account ignored); Origin vs allowed_domains; `POST visit` →
  Visit + `pixel.visit_recorded` audit. *Done when:* 401/403/201 specs + audit
  row + visit stores caller IP.
- **2.3 Normalizer.** email (lowercase, homoglyph-preserving) + phone (E.164-ish)
  normalization used everywhere identity is compared. *Done when:* unit specs
  incl. L-1008's Cyrillic `о` and CRM fixture numbers.
- **2.4 Credits::Reservation.** Row-lock deduction of Σ enabled-layer costs,
  ledger entry with breakdown + balance_after, `credits.reserved` /
  `credits.insufficient` audits. *Done when:* specs — happy, exact-balance,
  insufficient, concurrent threads keep `balance == Σ ledger`, CHECK holds.
- **2.5 Ingestion endpoint.** `Leads::IngestionService` transaction exactly per
  §8 steps 1–7; enqueue-after-commit (step 8); Redis-down rescue path; 201
  `{lead_id, stream_token}` (+ replay → 200 original). *Done when:* request
  specs — happy path creates lead+run+10 rows in correct states+reservation+3
  audit events; 402 hold path; replay; account-spoof payload ignored; jobs
  enqueued only after commit (asserted); enqueue failure keeps lead + audits.
- **2.6 Gateway + fixture store.** provider_responses seeding (9 files,
  comments stripped); `Providers::Gateway` lead_ref → identity-match → clean
  default; deterministic per-layer latency (0 in test). *Done when:* unit specs
  for all three lookup tiers + defaults for every layer key; seeds green.
- **2.7 Processors 1–5.** vpn_proxy, anura, trustedform, blacklist_alliance,
  dnc — full §11 verdict/score/panel_verdict/detail semantics.
  *Done when:* fixture-driven unit specs per processor (each seeded lead id
  that exercises it), incl. not_enabled and not_applicable paths.
- **2.8 Processors 6–10.** phone_validation (disagree vs all-VoIP vs invalid),
  email_validation, enrichment, duplicate_detection (exact vs soft window
  |Δ| ≤ 30d, crm_records seeded here), voice (sample → real verdicts;
  no sample → not_applicable). *Done when:* same bar; L-1004 exact + L-1012
  soft covered explicitly.
- **2.9 VerificationLayerJob.** CAS claim (pending→processing), gateway call,
  persist outcome, layer.* audit, errored-on-exhaustion path, `maybe_finalize`
  CAS check enqueueing FinalizeRunJob (job class exists now; its body lands in
  3.3 — spec asserts up to `finalizing` + enqueue). *Done when:* double-perform
  idempotency spec; two-thread CAS spec → single finalize enqueue.

**Phase 2 gate:** `bin/ci` green; a POSTed lead reaches `finalizing` with 10
correctly-stated layer rows, reservation, and a complete audit trail.

### 20.4 Phase 3 — Consensus, settlement, certificates, harness (Day 3)

- **3.1 Consensus::Policy.** defaults ⊕ layer_policies ⊕ account thresholds;
  snapshot hash. *Done when:* override/promotion/threshold specs.
- **3.2 Consensus::Engine.** HardStopEvaluator, SignalScorer, ReasonBuilder,
  bands, flags, §7.5 unavailability rules. *Done when:* full §17.1 matrix —
  every hard stop, band edges 39/40/69/70, exclusions, fail-open/closed.
- **3.3 Finalizer.** FinalizeRunJob body: verdict persist (+policy snapshot),
  certificate, settlement, lead denorm, ACCEPT→crm_records append,
  final_verdict broadcast, audits; idempotent under retry. *Done when:* rerun
  spec — second execution changes nothing (unique indexes hold).
- **3.4 Credits::Settlement + BurnRate.** Refund not_applicable/errored costs
  with breakdown; `credits.settled` audit; trailing-7d burn + fixture fallback;
  low-credit threshold flag event. *Done when:* refund math specs; invariant
  spec; `credits:audit` rake task passes.
- **3.5 Certificates.** CanonicalJson; Issuer (advisory lock, chain,
  sequence); Verifier; `/verify/:public_id` HTML + JSON. *Done when:* hash
  stable across jsonb round-trip; tamper → TAMPERED; chain-break detected;
  gapless sequence under concurrency spec.
- **3.6 Seeds B (leads) + 12-lead harness.** Ingest the 12 fixture leads
  through the real pipeline inline (latency 0, `expected_verdict` stripped);
  reconciling ledger `adjustment` per §10 so balances land exactly on
  `accounts.json`; `db:seed` prints derived-vs-hint verdict table + balances +
  logins. Harness spec asserts all 12 verdicts, key reasons, flags (L-1012
  soft_duplicate, L-1005 DNC-not-litigator), and post-seed balances.
  *Done when:* fresh `db:reset db:seed` prints a fully matching table; harness
  spec green.

**Phase 3 gate:** `bin/ci` green; harness green; `credits:audit` green on
seeded DB.

### 20.5 Phase 4 — Real-time, pixel, demo page (Day 4)

- **4.1 Channel + Broadcaster.** VerificationChannel (stream-token verify,
  reject without); full `Realtime::Broadcaster` (audit event → §14 wire shapes,
  score/100.0, rescue-safe); Turbo Stream broadcasts for CRM. *Done when:*
  channel specs (accept/reject/expiry); broadcaster unit specs per event type.
- **4.2 Polling fallback.** `GET /api/pixel/leads/:id/activity` (same shapes,
  `since` cursor, stream-token auth). *Done when:* request specs incl. auth.
- **4.3 Production super-pixel.js.** Same public API as the reference
  (`onActivity`, `attach`, auto-attach, data-* config); real /visit + /leads;
  dependency-free Cable wire client (subscribe, ping, capped backoff →
  polling); never-throw wrappers; form never blocked. *Done when:* manual
  smoke in dev + used by 4.4's system spec; zero console errors.
- **4.4 /demo page.** Assignment landing page served at /demo, snippet swapped
  to seeded SolarPro pixel + real endpoint; persona cheat-sheet panel (12
  identities); layout/aesthetic matches the root `image.png` reference
  (rewired, not restyled). *Done when:* system spec — submit persona → layer
  rows stream → final verdict; unknown identity → clean-default ACCEPT; L-1005
  persona phone → DNC hard stop shown; side-by-side check against `image.png`.
- **4.5 Pixel management.** CRUD (admin-only writes), allowed domains, layer
  checkboxes limited to account modules, cost/run readout,
  `Pixels::SnippetGenerator` + copy block; `pixel.created/updated` audits.
  *Done when:* request + policy specs; generated snippet loads on /demo
  verbatim.

**Phase 4 gate:** `bin/ci` green; demo page proves the pixel live end-to-end
with Sidekiq running.

### 20.6 Phase 5 — Dashboards (Day 4–5)

- **5.1 Shell.** App layout, nav (role-aware), Tailwind components, Pagy init,
  flash + error pages. *Done when:* system smoke per role.
- **5.2 CRM index.** Filters (verdict/status/flag/date) + normalized search +
  Pagy + Turbo Stream prepend on new verdicts; review-queue preset link
  (`?verdict=review`). *Done when:* filter/search specs; isolation spec;
  stream update spec.
- **5.3 Lead detail.** 10-layer three-state table with detail + timing; score,
  reasons, flags; audit timeline (§6); certificate link; re-verify button
  (on_hold / enqueue-failed only) → POST reverify re-runs pipeline.
  *Done when:* request specs incl. reverify happy + guard paths.
- **5.4 Certificates + credits pages.** Cert index/show (evidence table,
  chain/hash status); credits page (balance, ledger with breakdowns, burn,
  days-to-zero). *Done when:* specs incl. isolation.
- **5.5 Audit explorer (account).** Filter by event_type/subject/actor/date on
  §6 indexes; linked from lead timeline. *Done when:* filter specs + isolation.
- **5.6 Super-admin.** Dashboard: accounts table (plan, status w/ past_due
  badge, balance, used-%, burn, days-to-zero, flags — acct_autoinsure lights
  up), platform verdict split, recent platform events; account drill-down
  (read-only + ledger + pixels); global audit explorer. *Done when:* specs —
  member/account_admin get 404 on /admin, super_admin sees all three accounts.

**Phase 5 gate:** `bin/ci` green; click-through of every §19 route as each
role renders correctly with seeded data.

### 20.7 Phase 6 — Hardening, docs, completeness audit (Day 5)

- **6.1 Isolation sweep.** Request specs: every tenant resource (lead, pixel,
  certificate, audit event, credits, reverify) fetched cross-tenant by direct
  id → 404; param spoofing (account_id/pixel_id in payloads) ignored.
- **6.2 Race & idempotency suite.** Threaded double-finalize → one verdict/
  cert/settlement; double layer job; retried finalizer; concurrent
  reservations at boundary balance; replay POST storm.
- **6.3 Failure-mode suite.** Provider exception → errored + fail-open/closed
  verdicts per §7.5; broadcast raise swallowed; Redis down at enqueue → 201 +
  `system.enqueue_failed` + recoverable via reverify + `verification:requeue_stuck`.
- **6.4 README + bin/setup polish.** Prereqs (PG, Redis), `bin/setup`,
  `bin/dev`, URLs (/demo, /verify, /admin, /admin/sidekiq), seeded logins
  table, test instructions. *Done when:* fresh clone → README steps only →
  working demo (actually performed, not assumed).
- **6.5 SOLUTION.md.** Full §22 outline; explicit Q1–Q14 answers; stubs list;
  cuts list (if any) with reasons; next-week + risks.
- **6.6 Completeness audit — the final gate.** All of:
  1. `git grep -nE "TODO|FIXME|HACK|XXX|NotImplementedError|binding\.irb|byebug|console\.log"`
     → only the BaseProcessor contract line.
  2. Fresh `db:drop db:create db:migrate db:seed` → verdict table matches, balances match.
  3. `bin/ci` green (rubocop, brakeman, full rspec incl. system).
  4. Route coverage: every route in §19 exercised by at least one spec (script
     compares `rails routes` against spec request logs).
  5. Tree check: every §18 file exists; no orphan/unused files.
  6. §17 categories 1–9: each has specs, none pending/skipped (`rspec --dry-run`
     shows zero pending).
  7. Manual click-through: 3 role logins, CRM + filters, lead detail, cert
     verify (+ tamper demo via console UPDATE → TAMPERED), /demo live run with
     a persona and an unknown identity, admin dashboard flags, Sidekiq Web.
  8. EVALUATION.md self-score pass: walk the rubric line-by-line and confirm
     each scored item has a concrete artifact; anything missing goes back into
     a chunk, not into hope.
  9. Standards pass (§18.1): re-read every file under `app/` against the SRP,
     naming, and Rails rules — any class failing the "and" test, any vague or
     abbreviated name, any callback with side effects, any N+1 in a list view
     gets fixed now, as its own commit.

**Allowed-cut list if the timebox truly forces it — these exact scopes, in this
order, each recorded in SOLUTION.md with a reason:**
(a) chunk 5.5 entirely — account audit-explorer UI (events are still recorded
and remain visible on lead timelines); (b) from 5.3: the re-verify button only
(the `verification:requeue_stuck` rake task stays mandatory); (c) from 5.6: the
account drill-down page only (the accounts table + flags stay). Nothing else is
cuttable — phases 0–4 and 6 are never cut, and a cut not on this list is a
contract violation, not a judgement call.

---

## 21. Deliberate changes from CLAUDE_1.md (say these in the interview)

1. **Audit spine added** (§6) — CLAUDE_1.md had no audit/activity model at all,
   yet the assignment requires an activity timeline and it's the cheapest way to
   power the live panel, the CRM timeline, and compliance queries from one write.
2. **Finalization race fixed** (§9) — counting results in each layer job double-
   finalizes under concurrency: duplicate certificates + double credit movement.
   Now: pre-created rows + compare-and-set claim + idempotent finalizer + unique
   indexes as the DB backstop.
3. **Credits: reserve→settle with real module costs** (§10) — was flat 1/run
   deducted *after* the work, with failures swallowed (free verifications when
   broke, and it ignored `module_costs_in_credits`). Now funded up front,
   per-layer breakdown, refunds, ledger with `balance_after`, hold-not-drop on
   insufficient.
4. **Certificate hashing bug fixed** (§12) — jsonb reorders keys, so
   `SHA256(evidence.to_json)` fails verification after a DB round-trip. Canonical
   (sorted-key) JSON + per-account hash chain.
5. **Layer names unified** (§4) — `trusted_form`/`duplicate`/`voice_ai` vs the
   fixtures' `trustedform`/`duplicate_detection`/`voice` would silently break
   fixture lookups, enabled-module checks, cost lookup, and the landing-page
   labels.
6. **Voice implemented, not stubbed** — fixtures carry real voice verdicts;
   `human_reused_actor` is part of L-1009's REJECT. `has_sample:false` →
   not_applicable is the correct in-development behavior.
7. **Fixture ids as public_id columns** — seeding `Account.find_or_create_by!(id:
   "acct_solarpro")` breaks on bigint PKs. External-id pattern throughout.
8. **Gateway fallback for unknown identities** (§9) — erroring on every layer for
   any non-fixture lead means the *live demo fails*, the rubric's explicit red
   flag. Clean defaults + identity matching (typing a seed persona replays its
   scenario — a demo feature, not just a fix).
9. **CORS + replay + origin + stream-token auth** (§13) — the pixel is cross-
   origin; no CORS = dead embed. Client session ids are guessable; streams are
   now signed. Response contract fixed to `{lead_id, …}` (the reference pixel
   reads `res.lead_id`; CLAUDE_1.md returned `correlation_id` — panel would never
   subscribe).
10. **Error handling made honest** (§7) — "services never raise, rescue
    StandardError everywhere" swallows bugs and breaks Sidekiq retry semantics.
    Domain failures are Result values; unexpected exceptions surface to
    boundaries; per-layer fail-open/closed is explicit data.
11. **`require_tenant = true`** (§13) — unscoped-by-default with a super-admin
    bypass is exactly how tenant leaks ship; opt out explicitly, per admin action.
12. **Transactional ingestion + enqueue-after-commit** (§8) — CLAUDE_1.md created
    lead and run as separate unwrapped saves and enqueued mid-flow: a crash
    mid-sequence orphans partial state, and with Sidekiq (Redis ≠ your DB) an
    in-transaction enqueue can execute before the rows commit. The stack itself
    deliberately stays Sidekiq/Redis/Devise (§2) — matching CLAUDE_1.md and the
    presenter's production experience — with the operational discipline
    (after-commit enqueue, Redis-down recovery, authenticated Sidekiq Web) now
    specified instead of assumed.
13. **Calibration verified against account module sets** (§4, §11) — CLAUDE_1.md's
    engine assumed all layers exist for everyone; three expected verdicts are
    only reachable through *other* layers (L-1005 via DNC, L-1003 via Anura,
    L-1009 via Anura+VoIP). Weights were derived from and checked against all 12.
14. **Policy snapshot on every verdict** (§11) — verdicts remain explainable after
    a buyer tunes weights; pairs with the audit trail for "why did this reject?"
    forever.

---

## 22. SOLUTION.md outline (write on day 5, notes as you go)

Run instructions (bin/setup, bin/dev, /demo, logins) · data model diagram ·
consensus design + weight rationale + the 12-lead table · tenancy + credit model ·
ActionCable trade-off · audit architecture · security notes from pixel-spec §
(cross-account posts, replay, client vs server) · what's stubbed (vendors = seeded
gateway, email, payments) · known gaps + next week (behavioral scoring from dwell/
interactions, per-account webhooks, verdict override workflow with dual-control
audit, certificate export, provider circuit breakers, audit partitioning) ·
explicit answers Q1–Q14 (§ references above map one-to-one).

## 23. Out of scope (per assignment)

Real vendor calls, Stripe/billing, email delivery, mobile apps, impersonation,
pixel-perfect UI. Never read `expected_verdict` in app code — it lives only in
the seed report and the harness spec.
