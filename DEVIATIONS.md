# Deviations from the build plan

Running record of every place the implementation departs from `CLAUDE.md`, kept
as the work happens (per §22, "notes as you go") so `SOLUTION.md` can absorb it
at the end rather than reconstructing it from memory. Each entry states what the
plan said, what was built, and why.

---

## 1. `User` is not `acts_as_tenant` — the one unscoped tenant model

**Plan:** §13 — "`acts_as_tenant :account` on every tenant model."

**Built:** every tenant-owned model carries the default scope *except* `User`.

**Why:** authentication happens before a tenant exists. Devise looks a user up by
email on a session-less request, and there is no account to scope by until that
lookup has already succeeded. A tenant-scoped `User` would require the visitor to
name their account before signing in.

**Compensating controls**, all specced in `spec/models/tenancy_spec.rb`:

- `email` is globally unique, so a lookup can never straddle two accounts;
- the `users_account_matches_role` CHECK pins `account_id` to the role — a
  tenantless `account_admin` or a tenanted `super_admin` is impossible;
- Pundit denies by default on every user-facing action;
- **standing rule:** anything that lists or manages users loads through
  `account.users`, never `User.where(...)`.

## 2. `Layers::REGISTRY` is `Layers::Registry`

**Plan:** §4 refers to a `Layers::REGISTRY` constant; §18 lists the file
`app/services/layers/registry.rb`.

**Built:** a `Layers::Registry` module in exactly that file.

**Why:** Zeitwerk resolves `layers/registry.rb` to `Layers::Registry`; a constant
named `REGISTRY` in that path would not autoload. Defining both would be an alias,
and aliasing layer names is precisely the failure §4 exists to prevent — so there
is one name.

## 3. `Errors::ReplayDetected` does not exist

**Plan:** §7.1 lists it in the error taxonomy.

**Built:** replay is a `Result` code (`replay_detected`), never a raised exception.

**Why:** §7.3 requires a replayed submission to answer **200 with the original
`lead_id`**. That is a success outcome, and modelling it as an exception would
mean raising in order to return a normal response. Every other error in §7.1 is
present and used.

## 4. `frozen_string_literal` is not enforced under `config/`, `db/`, `spec/`

**Plan:** §18.1 — "`# frozen_string_literal: true` everywhere."

**Built:** enforced across `app/` and `lib/` (zero rubocop offenses); exempted for
`config/`, `db/` and `spec/` in `.rubocop.yml`.

**Why:** those trees are largely generated or DSL files where the pragma adds
noise without protecting anything shared. Application code — the part where a
mutated string literal could actually leak between requests — complies fully.

## 5. Model immutability is enforced at the model layer, not the database

`AuditEvent`, `ConsentCertificate` and `CreditLedgerEntry` are `readonly?` once
persisted and have no `updated_at`. `update_all` and raw SQL still bypass that,
which is **deliberate**: chunk 6.6's tamper demonstration depends on flipping a
stored certificate through the console and watching the verifier report
`TAMPERED`. Tamper-*evidence* is the hash chain; tamper-*prevention* at the
database level would make the evidence untestable.

## 6. `db:seed` writes to stdout

§20.0 forbids stray `puts` in delivered code. The seed loaders print a progress
summary, the derived credit cost per account, and the sign-in table — that output
is the deliverable of `db:seed`, not debugging residue. No `puts` exists under
`app/` or `lib/`.

---

## Environment note

Developed and tested on **Ruby 4.0.6** with Rails 8.1.3 and PostgreSQL 17. The
`Gemfile` floor is `>= 3.3.0` and nothing depends on 4.x behaviour, but 4.0 is
recent enough that the README should name the tested version rather than leave a
reader to infer it from `.ruby-version`.
