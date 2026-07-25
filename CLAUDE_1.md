# CLAUDE.md — Super Pixel Platform

This file is the single source of truth for how this codebase is built.
Read it fully before writing any code. Every architectural decision is here and every convention is non-negotiable.

---

## Project Overview

A multi-tenant Ruby on Rails platform that acts as a fraud and consent verification engine for lead generation. Publishers embed a JavaScript pixel snippet on their landing pages. When a visitor submits a lead form, the pixel posts the lead to this platform, which runs it through multiple fraud and consent detection layers in parallel, computes a consensus verdict (`ACCEPT` / `REVIEW` / `REJECT`), and issues a tamper-evident consent certificate.

**Core concepts:**
- **Account** — a tenant (a lead buyer company). All data is scoped to an account.
- **Pixel** — an embeddable snippet scoped to an account, configured with which detection layers to enable.
- **Lead** — a person who submitted a form. Belongs to a pixel (and therefore an account).
- **VerificationRun** — one processing attempt per lead. Runs all enabled detection layers.
- **LayerResult** — one row per layer per run. Captures verdict, raw response, and score contribution.
- **ConsensusVerdict** — the engine's final decision for a run.
- **ConsentCertificate** — immutable, SHA256-hashed proof issued per lead after verification.
- **CreditTransaction** — append-only ledger. One credit consumed per verification run.

---

## Tech Stack

- **Ruby on Rails 7.2+** — API + HTML rendering
- **PostgreSQL** — primary database
- **Redis** — ActionCable adapter, Sidekiq backend
- **Sidekiq** — background job processing
- **ActionCable** — real-time WebSocket streaming to landing page
- **Devise** — authentication
- **acts_as_tenant** — multi-tenant query scoping
- **Pundit** — role-based authorization
- **RSpec + FactoryBot** — testing

---

## Non-Negotiable Principles

### 1. Single Responsibility — Always

Every class does exactly one thing. The test: if you can describe a class using the word "and", split it.

```
# WRONG — does too much
class LeadProcessor
  def process(lead)
    validate_email(lead)    # ← responsibility 1
    call_external_api(lead) # ← responsibility 2
    save_result(lead)       # ← responsibility 3
    send_notification(lead) # ← responsibility 4
  end
end

# RIGHT — one job each
class Leads::EmailValidator; end
class Layers::AnuraProcessor; end
class Leads::VerificationRunCreator; end
class Leads::ConsentCertificateIssuer; end
```

### 2. Services Always Return a Result Struct

Every service object defines an internal `Result` Struct and always returns one. Services never raise. They rescue and return failure structs.

```ruby
class SomeService
  Result = Struct.new(:success?, :data, :errors, keyword_init: true) do
    def failure? = !success?
  end

  def initialize(params)
    @params = params
  end

  def call
    # ... logic
    Result.new(success?: true, data: { id: record.id }, errors: [])
  rescue StandardError => e
    Rails.logger.error("#{self.class.name} failed: #{e.message}")
    Result.new(success?: false, data: nil, errors: [e.message])
  end
end
```

**Why Struct over Hash:** A Hash typo (`result[:succss?]`) returns nil silently. A Struct typo raises `NoMethodError` immediately.
**Why Struct over OpenStruct:** Struct is defined at class load time — significantly faster for high-frequency service calls.

### 3. Orchestrators Coordinate. Services Execute.

```
Controller → Orchestrator → [ServiceA, ServiceB, ServiceC]
                                 ↓           ↓           ↓
                            Result       Result       Result
```

The orchestrator passes only what each service needs — never a full params hash. It checks `result.failure?` after each step and stops immediately.

```ruby
class Leads::IngestionOrchestrator
  Result = Struct.new(:success?, :lead, :errors, keyword_init: true)

  def initialize(pixel:, payload:)
    @pixel   = pixel
    @payload = payload
  end

  def call
    lead_result = Leads::Creator.new(pixel: @pixel, payload: @payload).call
    return failure(lead_result.errors) if lead_result.failure?

    run_result = Leads::VerificationRunCreator.new(lead: lead_result.data[:lead]).call
    return failure(run_result.errors) if run_result.failure?

    LeadIngestionJob.perform_later(run_result.data[:run].id)

    Result.new(success?: true, lead: lead_result.data[:lead], errors: [])
  end

  private

  def failure(errors)
    Result.new(success?: false, lead: nil, errors: errors)
  end
end
```

### 4. Thin Controllers. Thin Models.

**Controllers** — receive request, call one orchestrator or service, render result. Nothing else.

**Models** — associations, validations, named scopes, and nothing else. No business logic. No external calls.

```ruby
# WRONG — business logic in model
class Lead < ApplicationRecord
  def process!
    run_verification
    issue_certificate
    deduct_credits
  end
end

# RIGHT — model is a data layer only
class Lead < ApplicationRecord
  acts_as_tenant :account

  belongs_to :account
  belongs_to :pixel

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :phone, presence: true

  scope :accepted,  -> { joins(:consensus_verdict).where(consensus_verdicts: { verdict: "accept" }) }
  scope :rejected,  -> { joins(:consensus_verdict).where(consensus_verdicts: { verdict: "reject" }) }
  scope :pending,   -> { where.missing(:verification_runs) }
end
```

### 5. Small Methods. One Level of Abstraction.

Every method does one thing and fits on screen. Extract immediately when a method grows past ~10 lines.

```ruby
# WRONG — mixed levels of abstraction, too long
def compute_verdict(run)
  score = 100
  run.layer_results.each do |r|
    if r.layer_name == "vpn_proxy" && r.verdict == "vpn_detected"
      score -= 30
    elsif r.layer_name == "anura" && r.verdict == "bot"
      return build_reject_verdict(run, "Bot detected", 0, "anura")
    end
    # 40 more lines...
  end
end

# RIGHT — one level of abstraction per method
def compute_verdict(run)
  hard_stop = find_hard_stop(run.layer_results)
  return build_hard_stop_verdict(run, hard_stop) if hard_stop

  score = calculate_score(run.layer_results)
  build_scored_verdict(run, score)
end

def find_hard_stop(layer_results)
  layer_results.find { |r| hard_stop?(r) }
end

def hard_stop?(result)
  HARD_STOP_RULES[result.layer_name]&.call(result)
end
```

### 6. Rescue Specifically, Then Generally

```ruby
rescue Net::OpenTimeout, Net::ReadTimeout
  Result.new(success?: false, errors: ["Provider timed out"])
rescue Net::HTTPUnauthorized
  Result.new(success?: false, errors: ["Provider authentication failed"])
rescue StandardError => e
  Rails.logger.error("#{self.class.name}: #{e.class} — #{e.message}")
  Result.new(success?: false, errors: ["Unexpected error"])
end
```

### 7. Enums Are Symbols in Ruby 3, Strings in DB

```ruby
enum :status, { pending: "pending", running: "running", complete: "complete", failed: "failed" }
enum :verdict, { accept: "accept", review: "review", reject: "reject" }
enum :layer_status, { not_enabled: "not_enabled", not_applicable: "not_applicable", returned_verdict: "returned_verdict" }
```

---

## Folder Structure — Exact

```
app/
├── channels/
│   └── verification_channel.rb
│
├── controllers/
│   ├── application_controller.rb
│   ├── sessions_controller.rb
│   ├── api/
│   │   └── v1/
│   │       ├── base_controller.rb
│   │       ├── leads_controller.rb       # POST /api/v1/leads
│   │       └── visits_controller.rb      # POST /api/v1/visits (page visit tracking)
│   ├── admin/                            # super_admin only
│   │   ├── base_controller.rb
│   │   ├── accounts_controller.rb
│   │   ├── leads_controller.rb
│   │   └── dashboard_controller.rb
│   └── dashboard/                        # account_admin + member
│       ├── base_controller.rb
│       ├── pixels_controller.rb
│       ├── leads_controller.rb
│       └── certificates_controller.rb
│
├── jobs/
│   ├── application_job.rb
│   ├── lead_ingestion_job.rb             # orchestrates verification run
│   └── layer_processing_job.rb           # processes one layer, broadcasts result
│
├── models/
│   ├── application_record.rb
│   ├── account.rb
│   ├── user.rb
│   ├── pixel.rb
│   ├── lead.rb
│   ├── visit.rb                          # page visit events before form submit
│   ├── verification_run.rb
│   ├── layer_result.rb
│   ├── layer_policy.rb                   # per-account layer configuration
│   ├── consensus_verdict.rb
│   ├── consent_certificate.rb
│   └── credit_transaction.rb
│
├── services/
│   ├── concerns/
│   │   └── result_struct.rb              # shared Result Struct mixin
│   │
│   ├── consensus/
│   │   ├── engine.rb                     # main entry: runs hard stops + scoring
│   │   ├── hard_stop_evaluator.rb        # checks if any layer is a hard stop
│   │   ├── signal_scorer.rb             # converts layer results to score
│   │   └── verdict_builder.rb           # creates ConsensusVerdict record
│   │
│   ├── layers/
│   │   ├── base_processor.rb             # shared interface all processors inherit
│   │   ├── vpn_proxy_processor.rb
│   │   ├── anura_processor.rb
│   │   ├── trusted_form_processor.rb
│   │   ├── blacklist_alliance_processor.rb
│   │   ├── dnc_processor.rb
│   │   ├── phone_validation_processor.rb
│   │   ├── email_validation_processor.rb
│   │   ├── data_enrichment_processor.rb
│   │   ├── duplicate_detection_processor.rb
│   │   └── voice_ai_processor.rb         # stub — returns not_applicable
│   │
│   ├── leads/
│   │   ├── ingestion_orchestrator.rb     # top-level: creates lead + queues job
│   │   ├── creator.rb                   # creates Lead record
│   │   ├── verification_run_creator.rb  # creates VerificationRun record
│   │   └── consent_certificate_issuer.rb # issues ConsentCertificate
│   │
│   ├── pixels/
│   │   └── snippet_generator.rb         # generates JS embed code for a pixel
│   │
│   └── credits/
│       └── deduction_service.rb         # atomic credit deduction with row lock
│
├── policies/
│   ├── application_policy.rb
│   ├── account_policy.rb
│   ├── lead_policy.rb
│   ├── pixel_policy.rb
│   └── consent_certificate_policy.rb
│
├── views/
│   ├── layouts/
│   │   ├── application.html.erb
│   │   └── admin.html.erb
│   ├── sessions/
│   ├── admin/
│   │   ├── dashboard/
│   │   ├── accounts/
│   │   └── leads/
│   └── dashboard/
│       ├── pixels/
│       ├── leads/
│       └── certificates/
│
└── helpers/
    └── application_helper.rb

config/
├── routes.rb
└── initializers/
    └── acts_as_tenant.rb

db/
├── migrate/
└── seeds/
    ├── accounts.rb
    ├── users.rb
    ├── leads.rb
    └── mock_providers.rb

spec/
├── factories/
│   ├── accounts.rb
│   ├── users.rb
│   ├── pixels.rb
│   ├── leads.rb
│   ├── verification_runs.rb
│   ├── layer_results.rb
│   └── consensus_verdicts.rb
├── models/
├── services/
│   ├── consensus/
│   │   ├── engine_spec.rb
│   │   ├── hard_stop_evaluator_spec.rb
│   │   └── signal_scorer_spec.rb
│   └── leads/
│       └── ingestion_orchestrator_spec.rb
├── requests/
│   ├── api/
│   │   └── v1/
│   │       └── leads_spec.rb
│   └── dashboard/
│       └── leads_spec.rb
└── support/
    ├── factory_bot.rb
    ├── devise.rb
    └── tenant_helpers.rb
```

---

## Database Schema — Full

Run migrations in this exact order.

### accounts

```ruby
create_table :accounts do |t|
  t.string  :name,             null: false
  t.string  :plan,             null: false, default: "starter"
  t.integer :credit_balance,   null: false, default: 0
  t.string  :status,           null: false, default: "active"   # active / suspended / past_due
  t.jsonb   :settings,         null: false, default: {}
  t.timestamps
end
add_index :accounts, :status
```

### users

```ruby
create_table :users do |t|
  t.references :account, foreign_key: true, index: true, null: true  # null for super_admin
  t.string  :email,              null: false
  t.string  :encrypted_password, null: false
  t.string  :role,               null: false, default: "member"  # super_admin / account_admin / member
  t.string  :first_name
  t.string  :last_name
  t.timestamps
end
add_index :users, :email, unique: true
add_index :users, [:account_id, :role]
```

### pixels

```ruby
create_table :pixels do |t|
  t.references :account, null: false, foreign_key: true, index: true
  t.string  :name,            null: false
  t.string  :api_key,         null: false
  t.string  :secret_key,      null: false   # for HMAC verification
  t.string  :allowed_domains, null: false, array: true, default: []
  t.string  :enabled_layers,  null: false, array: true, default: []
  t.boolean :active,          null: false, default: true
  t.timestamps
end
add_index :pixels, :api_key, unique: true
add_index :pixels, [:account_id, :active]
```

### leads

```ruby
create_table :leads do |t|
  t.references :account, null: false, foreign_key: true, index: true
  t.references :pixel,   null: false, foreign_key: true, index: true
  t.string  :first_name
  t.string  :last_name
  t.string  :email
  t.string  :phone
  t.string  :ip_address
  t.string  :user_agent
  t.string  :referrer
  t.string  :page_url
  t.string  :correlation_id,   null: false   # UUID from pixel, travels across systems
  t.jsonb   :raw_payload,      null: false, default: {}
  t.datetime :submitted_at,    null: false
  t.timestamps
end
add_index :leads, :correlation_id, unique: true
add_index :leads, [:account_id, :created_at]
add_index :leads, [:account_id, :email]
add_index :leads, [:account_id, :phone]
```

### visits

```ruby
create_table :visits do |t|
  t.references :account, null: false, foreign_key: true, index: true
  t.references :pixel,   null: false, foreign_key: true, index: true
  t.string  :correlation_id, null: false
  t.string  :ip_address
  t.string  :user_agent
  t.string  :page_url
  t.datetime :visited_at, null: false
  t.jsonb   :metadata, default: {}   # keystroke timing, form events etc
  t.timestamps
end
add_index :visits, :correlation_id
```

### verification_runs

```ruby
create_table :verification_runs do |t|
  t.references :lead, null: false, foreign_key: true, index: true
  t.string  :status, null: false, default: "pending"   # pending / running / complete / failed
  t.datetime :started_at
  t.datetime :completed_at
  t.timestamps
end
add_index :verification_runs, [:lead_id, :status]
```

### layer_results

```ruby
create_table :layer_results do |t|
  t.references :verification_run, null: false, foreign_key: true, index: true
  t.string  :layer_name,    null: false
  t.string  :layer_status,  null: false   # not_enabled / not_applicable / returned_verdict
  t.string  :verdict                      # layer-specific: pass / fail / review / error — null if not returned_verdict
  t.integer :score_adjustment, default: 0  # negative = bad signal
  t.jsonb   :raw_response,  default: {}
  t.string  :error_message
  t.datetime :processed_at
  t.timestamps
end
add_index :layer_results, [:verification_run_id, :layer_name], unique: true
add_index :layer_results, [:verification_run_id, :layer_status]
```

### layer_policies

```ruby
# Per-account configuration — allows buyers to tune the engine without code changes
create_table :layer_policies do |t|
  t.references :account, null: false, foreign_key: true, index: true
  t.string  :layer_name,         null: false
  t.boolean :enabled,            null: false, default: true
  t.boolean :treat_as_hard_stop, null: false, default: false   # e.g. promote "suspected_litigator" to hard stop
  t.integer :weight_override                                    # null = use system default
  t.timestamps
end
add_index :layer_policies, [:account_id, :layer_name], unique: true
```

### consensus_verdicts

```ruby
create_table :consensus_verdicts do |t|
  t.references :verification_run, null: false, foreign_key: true, index: { unique: true }
  t.string  :verdict,          null: false   # accept / review / reject
  t.text    :reason,           null: false
  t.integer :score,            null: false
  t.string  :hard_stop_layer            # which layer triggered hard stop, if any
  t.jsonb   :layer_summary,   default: {}  # snapshot of all layer verdicts for certificate
  t.datetime :issued_at,      null: false
  t.timestamps
end
```

### consent_certificates

```ruby
# INSERT ONLY — never updated. Immutable by convention enforced at DB level.
create_table :consent_certificates do |t|
  t.references :lead,             null: false, foreign_key: true, index: true
  t.references :verification_run, null: false, foreign_key: true, index: { unique: true }
  t.string  :certificate_uuid,    null: false   # public reference UUID
  t.string  :certificate_hash,    null: false   # SHA256(evidence.to_json) — tamper detection
  t.string  :verdict,             null: false
  t.string  :trusted_form_reference             # from TrustedForm layer result
  t.jsonb   :evidence,            null: false   # full snapshot at time of issuance
  t.datetime :issued_at,          null: false
  # NO updated_at — append-only by design
  t.datetime :created_at,         null: false
end
add_index :consent_certificates, :certificate_uuid, unique: true
add_index :consent_certificates, :certificate_hash
```

### credit_transactions

```ruby
# Append-only accounting ledger — never updated, never deleted
create_table :credit_transactions do |t|
  t.references :account,          null: false, foreign_key: true, index: true
  t.references :verification_run, foreign_key: true, index: true, null: true
  t.integer  :amount,             null: false   # negative = deduction, positive = addition
  t.string   :reason,             null: false   # "verification_run" / "credit_purchase" / "refund"
  t.datetime :created_at,         null: false
  # NO updated_at — append-only
end
add_index :credit_transactions, [:account_id, :created_at]
```

---

## Multi-Tenancy — Implementation

Use `acts_as_tenant` on every account-scoped model. Set the tenant in `ApplicationController`. `super_admin` users have `nil` account — they bypass tenant scoping.

```ruby
# config/initializers/acts_as_tenant.rb
ActsAsTenant.configure do |config|
  config.require_tenant = false  # allow super_admin with no tenant
end

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Pundit::Authorization
  before_action :authenticate_user!
  before_action :set_tenant

  private

  def set_tenant
    return if current_user&.super_admin?
    ActsAsTenant.current_tenant = current_user&.account
  end
end

# app/models/lead.rb
class Lead < ApplicationRecord
  acts_as_tenant :account
  # Lead.all now auto-scopes: WHERE account_id = ?
  # No need to manually add account_id to every query
end
```

**Enforce at query level, not just UI level.** Pundit policies are the second layer, not the first.

```ruby
# app/policies/lead_policy.rb
class LeadPolicy < ApplicationPolicy
  def show?
    # acts_as_tenant already ensures record.account_id == current account
    # Pundit adds role-based check on top
    user.account_admin? || user.member?
  end

  def index? = show?
end
```

**Test for cross-tenant leakage — this test must exist and must pass:**

```ruby
RSpec.describe "Tenant isolation", type: :request do
  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }
  let(:user_a)    { create(:user, account: account_a) }
  let(:lead_b)    { create(:lead, account: account_b) }

  it "returns 404 when accessing another account's lead" do
    sign_in user_a
    get dashboard_lead_path(lead_b)
    expect(response).to have_http_status(:not_found)
    # 404 — not 403 — so existence is not revealed
  end
end
```

---

## Roles & Authorization

```ruby
# Three roles:
# super_admin  — platform operator. Sees all accounts. No account_id (nil).
# account_admin — can manage pixels, view all leads, manage users in their account
# member        — read-only access to leads and certificates in their account

# app/models/user.rb
class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :rememberable, :validatable

  enum :role, {
    super_admin:   "super_admin",
    account_admin: "account_admin",
    member:        "member"
  }

  belongs_to :account, optional: true

  validates :account, presence: true, unless: :super_admin?
end
```

---

## Detection Layers — Implementation Pattern

All layer processors follow the same interface via inheritance.

```ruby
# app/services/layers/base_processor.rb
module Layers
  class BaseProcessor
    Result = Struct.new(:status, :verdict, :score_adjustment, :raw_response, :error_message,
                        keyword_init: true)

    # status: not_enabled / not_applicable / returned_verdict

    def initialize(lead:, verification_run:, mock_data: nil)
      @lead             = lead
      @verification_run = verification_run
      @mock_data        = mock_data  # loaded from mock-data/ files
    end

    def call
      raise NotImplementedError, "#{self.class.name} must implement #call"
    end

    protected

    def not_enabled
      Result.new(status: "not_enabled", verdict: nil, score_adjustment: 0,
                 raw_response: {}, error_message: nil)
    end

    def not_applicable
      Result.new(status: "not_applicable", verdict: nil, score_adjustment: 0,
                 raw_response: {}, error_message: nil)
    end

    def returned_verdict(verdict:, score_adjustment:, raw_response:)
      Result.new(status: "returned_verdict", verdict: verdict,
                 score_adjustment: score_adjustment,
                 raw_response: raw_response, error_message: nil)
    end

    def error_result(message)
      Result.new(status: "returned_verdict", verdict: "error",
                 score_adjustment: 0, raw_response: {}, error_message: message)
    end
  end
end
```

```ruby
# app/services/layers/vpn_proxy_processor.rb
module Layers
  class VpnProxyProcessor < BaseProcessor
    def call
      return not_enabled unless layer_enabled?

      data = find_mock_data
      return error_result("No mock data for IP: #{@lead.ip_address}") unless data

      if data["is_vpn"] || data["is_proxy"] || data["is_tor"]
        returned_verdict(
          verdict:         "vpn_detected",
          score_adjustment: -30,
          raw_response:    data
        )
      else
        returned_verdict(
          verdict:         "clean",
          score_adjustment: 0,
          raw_response:    data
        )
      end
    end

    private

    def layer_enabled?
      @verification_run.lead.pixel.enabled_layers.include?("vpn_proxy")
    end

    def find_mock_data
      # Load from mock-data/vpn_proxy.json, find record matching lead IP
      @mock_data&.find { |d| d["ip"] == @lead.ip_address }
    end
  end
end
```

**All layer processors follow the same pattern.** Different logic, identical interface.

**Hard stop layers:** `blacklist_alliance` (confirmed_litigator verdict), `dnc` (on_dnc_list verdict), `trusted_form` (missing or mismatch verdict), `anura` (bot or malware verdict), `duplicate` (exact_duplicate verdict).

**Soft signal layers:** `vpn_proxy`, `phone_validation`, `email_validation`, `data_enrichment`, `anura` when suspicious (not bot).

**Voice AI:** Return `not_applicable` — in development, not yet implemented.

---

## Consensus Engine — Implementation

```ruby
# app/services/consensus/engine.rb
module Consensus
  class Engine
    Result = Struct.new(:success?, :verdict, :errors, keyword_init: true)

    # Layers that immediately reject regardless of score
    # Values can be overridden per-account via LayerPolicy
    DEFAULT_HARD_STOP_RULES = {
      "blacklist_alliance" => ->(r) { r.verdict == "confirmed_litigator" },
      "dnc"               => ->(r) { r.verdict == "on_dnc_list" },
      "trusted_form"      => ->(r) { r.verdict.in?(%w[missing mismatch]) },
      "anura"             => ->(r) { r.verdict.in?(%w[bot malware]) },
      "duplicate"         => ->(r) { r.verdict == "exact_duplicate" }
    }.freeze

    # Base score starts at 100. Signals subtract. Final score determines verdict.
    SCORE_THRESHOLDS = {
      accept: 70,
      review: 40
      # below 40 = reject
    }.freeze

    def initialize(verification_run)
      @run      = verification_run
      @account  = verification_run.lead.account
      @results  = verification_run.layer_results.where(layer_status: "returned_verdict")
    end

    def call
      hard_stop = Consensus::HardStopEvaluator.new(@results, @account).call
      if hard_stop
        verdict = Consensus::VerdictBuilder.new(@run, "reject", hard_stop.reason, 0, hard_stop.layer_name).call
        return Result.new(success?: true, verdict: verdict, errors: [])
      end

      score = Consensus::SignalScorer.new(@results, @account).call
      verdict_name = score_to_verdict(score.total)
      reason = score.reasons.join("; ").presence || "All checks passed"

      verdict = Consensus::VerdictBuilder.new(@run, verdict_name, reason, score.total, nil).call
      Result.new(success?: true, verdict: verdict, errors: [])
    rescue StandardError => e
      Rails.logger.error("Consensus::Engine failed: #{e.message}")
      Result.new(success?: false, verdict: nil, errors: [e.message])
    end

    private

    def score_to_verdict(score)
      if score >= SCORE_THRESHOLDS[:accept]
        "accept"
      elsif score >= SCORE_THRESHOLDS[:review]
        "review"
      else
        "reject"
      end
    end
  end
end
```

```ruby
# app/services/consensus/hard_stop_evaluator.rb
module Consensus
  class HardStopEvaluator
    HardStop = Struct.new(:layer_name, :reason, keyword_init: true)

    def initialize(layer_results, account)
      @layer_results = layer_results
      @account       = account
    end

    def call
      @layer_results.each do |result|
        stop = evaluate_result(result)
        return stop if stop
      end
      nil
    end

    private

    def evaluate_result(result)
      # Check account-level policy override first
      policy = LayerPolicy.find_by(account: @account, layer_name: result.layer_name)

      rule = Consensus::Engine::DEFAULT_HARD_STOP_RULES[result.layer_name]
      promoted = policy&.treat_as_hard_stop?

      if (rule && rule.call(result)) || (promoted && result.verdict.present?)
        HardStop.new(
          layer_name: result.layer_name,
          reason: "#{result.layer_name}: #{result.verdict}"
        )
      end
    end
  end
end
```

```ruby
# app/services/consensus/signal_scorer.rb
module Consensus
  class SignalScorer
    # Default weights — can be overridden per-account via LayerPolicy
    DEFAULT_WEIGHTS = {
      "vpn_proxy"          => { "vpn_detected" => -30 },
      "anura"              => { "suspicious" => -20 },
      "phone_validation"   => { "providers_disagree" => -15, "invalid" => -25 },
      "email_validation"   => { "providers_disagree" => -15, "invalid" => -25 },
      "data_enrichment"    => { "sources_disagree" => -10 },
      "blacklist_alliance" => { "suspected_litigator" => -25 },
      "trusted_form"       => { "expired" => -15, "partial_match" => -10 }
    }.freeze

    Score = Struct.new(:total, :reasons, keyword_init: true)

    def initialize(layer_results, account)
      @layer_results = layer_results
      @account       = account
    end

    def call
      total   = 100
      reasons = []

      @layer_results.each do |result|
        adjustment = weight_for(result)
        next if adjustment.zero?

        total   += adjustment
        reasons << "#{result.layer_name}: #{result.verdict} (#{adjustment})"
      end

      Score.new(total: total, reasons: reasons)
    end

    private

    def weight_for(result)
      policy = LayerPolicy.find_by(account: @account, layer_name: result.layer_name)
      policy&.weight_override ||
        DEFAULT_WEIGHTS.dig(result.layer_name, result.verdict) ||
        0
    end
  end
end
```

```ruby
# app/services/consensus/verdict_builder.rb
module Consensus
  class VerdictBuilder
    def initialize(run, verdict, reason, score, hard_stop_layer)
      @run             = run
      @verdict         = verdict
      @reason          = reason
      @score           = score
      @hard_stop_layer = hard_stop_layer
    end

    def call
      ConsensusVerdict.create!(
        verification_run: @run,
        verdict:          @verdict,
        reason:           @reason,
        score:            @score,
        hard_stop_layer:  @hard_stop_layer,
        layer_summary:    build_layer_summary,
        issued_at:        Time.current
      )
    end

    private

    def build_layer_summary
      @run.layer_results.each_with_object({}) do |r, h|
        h[r.layer_name] = { status: r.layer_status, verdict: r.verdict }
      end
    end
  end
end
```

---

## Background Jobs

```ruby
# app/jobs/lead_ingestion_job.rb
class LeadIngestionJob < ApplicationJob
  queue_as :leads
  sidekiq_options retry: 3

  def perform(verification_run_id)
    run  = VerificationRun.find(verification_run_id)
    lead = run.lead

    ActsAsTenant.with_tenant(lead.account) do
      run.update!(status: "running", started_at: Time.current)

      # Queue one job per layer — they process in parallel
      enabled_layers(run).each do |layer_name|
        LayerProcessingJob.perform_later(run.id, layer_name)
      end
    end
  end

  private

  def enabled_layers(run)
    run.lead.pixel.enabled_layers
  end
end
```

```ruby
# app/jobs/layer_processing_job.rb
class LayerProcessingJob < ApplicationJob
  queue_as :layers
  sidekiq_options retry: 3

  PROCESSOR_MAP = {
    "vpn_proxy"          => Layers::VpnProxyProcessor,
    "anura"              => Layers::AnuraProcessor,
    "trusted_form"       => Layers::TrustedFormProcessor,
    "blacklist_alliance" => Layers::BlacklistAllianceProcessor,
    "dnc"                => Layers::DncProcessor,
    "phone_validation"   => Layers::PhoneValidationProcessor,
    "email_validation"   => Layers::EmailValidationProcessor,
    "data_enrichment"    => Layers::DataEnrichmentProcessor,
    "duplicate"          => Layers::DuplicateDetectionProcessor,
    "voice_ai"           => Layers::VoiceAiProcessor
  }.freeze

  def perform(verification_run_id, layer_name)
    run  = VerificationRun.find(verification_run_id)
    lead = run.lead

    ActsAsTenant.with_tenant(lead.account) do
      processor_class = PROCESSOR_MAP.fetch(layer_name)
      result = processor_class.new(lead: lead, verification_run: run).call

      layer_result = LayerResult.create!(
        verification_run: run,
        layer_name:       layer_name,
        layer_status:     result.status,
        verdict:          result.verdict,
        score_adjustment: result.score_adjustment,
        raw_response:     result.raw_response,
        error_message:    result.error_message,
        processed_at:     Time.current
      )

      # Broadcast result to live landing page
      broadcast_layer_result(run, layer_name, layer_result)

      # If all layers are done, run consensus engine
      finalize_run_if_complete(run)
    end
  end

  private

  def broadcast_layer_result(run, layer_name, layer_result)
    ActionCable.server.broadcast(
      "verification_#{run.lead.correlation_id}",
      {
        type:    "layer_result",
        layer:   layer_name,
        status:  layer_result.layer_status,
        verdict: layer_result.verdict
      }
    )
  end

  def finalize_run_if_complete(run)
    expected_count = run.lead.pixel.enabled_layers.count
    actual_count   = run.layer_results.count

    return unless actual_count >= expected_count

    verdict = Consensus::Engine.new(run).call

    certificate = Leads::ConsentCertificateIssuer.new(
      lead:    run.lead,
      run:     run,
      verdict: verdict.verdict
    ).call

    Credits::DeductionService.new(account: run.lead.account, run: run).call

    run.update!(status: "complete", completed_at: Time.current)

    ActionCable.server.broadcast(
      "verification_#{run.lead.correlation_id}",
      {
        type:        "final_verdict",
        verdict:     verdict.verdict&.verdict,
        reason:      verdict.verdict&.reason,
        certificate: certificate.data&.dig(:uuid)
      }
    )
  end
end
```

---

## Real-Time Channel

```ruby
# app/channels/verification_channel.rb
class VerificationChannel < ApplicationCable::Channel
  def subscribed
    correlation_id = params[:correlation_id]
    stream_from "verification_#{correlation_id}"
  end

  def unsubscribed
    stop_all_streams
  end
end
```

The JavaScript pixel subscribes using the `correlation_id` UUID generated when the form loads. This UUID is submitted with the lead and used to route broadcasts back to the correct browser tab.

---

## Consent Certificate Issuance

```ruby
# app/services/leads/consent_certificate_issuer.rb
module Leads
  class ConsentCertificateIssuer
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    def initialize(lead:, run:, verdict:)
      @lead    = lead
      @run     = run
      @verdict = verdict
    end

    def call
      evidence    = build_evidence
      hash        = compute_hash(evidence)
      tf_ref      = extract_trusted_form_reference

      cert = ConsentCertificate.create!(
        lead:                  @lead,
        verification_run:      @run,
        certificate_uuid:      SecureRandom.uuid,
        certificate_hash:      hash,
        verdict:               @verdict,
        trusted_form_reference: tf_ref,
        evidence:              evidence,
        issued_at:             Time.current
      )

      Result.new(success?: true, data: { uuid: cert.certificate_uuid }, errors: [])
    rescue StandardError => e
      Result.new(success?: false, data: nil, errors: [e.message])
    end

    private

    def build_evidence
      {
        lead_id:         @lead.id,
        pixel_id:        @lead.pixel_id,
        account_id:      @lead.account_id,
        correlation_id:  @lead.correlation_id,
        submitted_at:    @lead.submitted_at.iso8601,
        ip_address:      @lead.ip_address,
        user_agent:      @lead.user_agent,
        page_url:        @lead.page_url,
        verdict:         @verdict,
        layer_results:   layer_results_snapshot,
        issued_at:       Time.current.iso8601
      }
    end

    def compute_hash(evidence)
      Digest::SHA256.hexdigest(evidence.to_json)
    end

    def extract_trusted_form_reference
      @run.layer_results
          .find_by(layer_name: "trusted_form")
          &.raw_response
          &.dig("certificate_id")
    end

    def layer_results_snapshot
      @run.layer_results.map do |r|
        { layer: r.layer_name, status: r.layer_status, verdict: r.verdict }
      end
    end
  end
end
```

---

## Credit Accounting

```ruby
# app/services/credits/deduction_service.rb
module Credits
  class DeductionService
    Result = Struct.new(:success?, :errors, keyword_init: true)

    COST_PER_VERIFICATION = 1

    def initialize(account:, run:)
      @account = account
      @run     = run
    end

    def call
      @account.with_lock do
        if @account.credit_balance < COST_PER_VERIFICATION
          return Result.new(success?: false, errors: ["Insufficient credits"])
        end

        @account.decrement!(:credit_balance, COST_PER_VERIFICATION)

        CreditTransaction.create!(
          account:          @account,
          verification_run: @run,
          amount:           -COST_PER_VERIFICATION,
          reason:           "verification_run"
        )
      end

      Result.new(success?: true, errors: [])
    rescue StandardError => e
      Result.new(success?: false, errors: [e.message])
    end
  end
end
```

**What happens when an account hits zero mid-verification:** The verification run completes but no credit is deducted — the `DeductionService` returns failure. The lead is marked with the verdict but flagged. The super-admin dashboard highlights accounts below 10 credits as "low" and at 0 as "suspended."

---

## API Controller — Pixel Endpoint

```ruby
# app/controllers/api/v1/base_controller.rb
module Api
  module V1
    class BaseController < ActionController::API
      before_action :authenticate_pixel!

      private

      def authenticate_pixel!
        @pixel = Pixel.find_by(api_key: request.headers["X-Pixel-Key"])
        render json: { error: "Unauthorized" }, status: :unauthorized unless @pixel&.active?
      end
    end
  end
end

# app/controllers/api/v1/leads_controller.rb
module Api
  module V1
    class LeadsController < BaseController
      def create
        result = Leads::IngestionOrchestrator.new(
          pixel:   @pixel,
          payload: lead_params
        ).call

        if result.success?
          render json: { correlation_id: result.lead.correlation_id }, status: :accepted
        else
          render json: { errors: result.errors }, status: :unprocessable_entity
        end
      end

      private

      def lead_params
        params.permit(
          :first_name, :last_name, :email, :phone,
          :ip_address, :user_agent, :referrer, :page_url,
          :correlation_id, :trusted_form_cert_id
        )
      end
    end
  end
end
```

---

## Routes

```ruby
Rails.application.routes.draw do
  # Authentication
  devise_for :users, controllers: { sessions: "sessions" }

  # Pixel API — unauthenticated, API key auth
  namespace :api do
    namespace :v1 do
      resources :visits, only: [:create]
      resources :leads,  only: [:create]
    end
  end

  # Super admin — all accounts
  namespace :admin do
    root to: "dashboard#index"
    resources :accounts, only: [:index, :show]
    resources :leads,    only: [:index, :show]
  end

  # Account dashboard — scoped to current account
  namespace :dashboard do
    root to: "leads#index"
    resources :pixels,       only: [:index, :new, :create, :show, :edit, :update]
    resources :leads,        only: [:index, :show]
    resources :certificates, only: [:show]
  end

  # Public certificate verification
  resources :certificates, only: [:show], param: :uuid
end
```

---

## Seeds

Load all mock data from the provided `mock-data/` JSON files. Structure seeds as separate files per entity.

```ruby
# db/seeds.rb
require_relative "seeds/accounts"
require_relative "seeds/users"
require_relative "seeds/pixels"
require_relative "seeds/leads"
require_relative "seeds/mock_providers"
```

Seed file pattern:

```ruby
# db/seeds/accounts.rb
puts "Seeding accounts..."
accounts_data = JSON.parse(File.read(Rails.root.join("mock-data/accounts.json")))

accounts_data.each do |data|
  Account.find_or_create_by!(id: data["id"]) do |a|
    a.name           = data["name"]
    a.plan           = data["plan"]
    a.credit_balance = data["credit_balance"]
    a.status         = data["status"]
  end
end
puts "  #{Account.count} accounts seeded"
```

---

## Testing Priorities

Test these in this order — they are the highest-value tests:

**1. Consensus engine — test every verdict path:**
```ruby
RSpec.describe Consensus::Engine do
  describe "#call" do
    context "when a hard stop layer fires" do
      it "returns REJECT with the hard stop layer name" do
        # ...
      end
    end

    context "when soft signals accumulate below threshold" do
      it "returns REJECT" do ... end
    end

    context "when signals are within review range" do
      it "returns REVIEW" do ... end
    end

    context "when all layers pass" do
      it "returns ACCEPT" do ... end
    end

    context "when a layer is unavailable" do
      it "continues processing remaining layers" do ... end
    end
  end
end
```

**2. Tenant isolation — cross-account access must always return 404:**
```ruby
RSpec.describe "Tenant isolation" do
  it "cannot access another account's lead"
  it "cannot access another account's pixel"
  it "cannot access another account's certificate"
end
```

**3. Credit deduction atomicity:**
```ruby
RSpec.describe Credits::DeductionService do
  it "does not deduct when balance is zero"
  it "is atomic under concurrent requests"
end
```

---

## Pixel Snippet Generation

```ruby
# app/services/pixels/snippet_generator.rb
module Pixels
  class SnippetGenerator
    def initialize(pixel)
      @pixel = pixel
    end

    def call
      <<~JS
        <!-- Super Pixel — #{@pixel.name} -->
        <script>
          (function() {
            window.SuperPixel = {
              pixelKey: "#{@pixel.api_key}",
              endpoint: "#{Rails.application.routes.url_helpers.api_v1_leads_url}"
            };
          })();
        </script>
        <script src="#{Rails.application.routes.url_helpers.root_url}super-pixel.js" async></script>
      JS
    end
  end
end
```

---

## Key Rails Conventions — Never Violate

- **Migrations:** Always use `null: false` unless a column is genuinely optional. Default values in DB, not just Rails.
- **Indexes:** Every foreign key gets an index. Every column used in a WHERE clause gets an index.
- **CONCURRENT indexes:** `add_index :leads, :email, algorithm: :concurrently` — never lock a production table.
- **Enums:** Define as strings (`enum :status, { active: "active" }`), not integers. Readable in the DB.
- **Scopes:** Named scopes on models — never put `.where()` chains in controllers or services.
- **No callbacks for business logic:** `after_create`, `before_save` etc. are for data normalisation only. Business logic belongs in services.
- **Fat service, thin model, thin controller:** Business complexity lives in `app/services/`, not anywhere else.
- **One Struct per service:** Define `Result = Struct.new(...)` at the top of every service class.
- **Keyword arguments:** Use `keyword_init: true` on all Structs. Use `def initialize(lead:, run:)` named params everywhere.
- **Method length:** If a method is longer than 10 lines, extract.
- **Naming:** Services are nouns (`Creator`, `Issuer`, `Deductor`) or verb phrases (`IngestionOrchestrator`). Jobs are verbs (`LeadIngestionJob`). Be specific.

---

## What Not To Build

- Real external vendor API calls — read from `mock-data/` JSON files
- Real Stripe/payment integration — credit balance is just a DB integer
- Email delivery — stub mailers
- Native mobile app
- Hardcoded verdicts based on `expected_verdict` hints in mock data — the engine must compute them

---

## Priority Order If Time Is Short

1. Auth + multi-tenancy (acts_as_tenant, roles, tenant isolation test)
2. Lead ingestion endpoint + LayerResult creation
3. Consensus engine (HardStopEvaluator + SignalScorer + VerdictBuilder)
4. ConsentCertificate issuance
5. ActionCable real-time wiring to landing page
6. CRM view (leads list + per-lead breakdown)
7. Credit accounting
8. Super-admin dashboard
9. Pixel snippet generation

**Depth over breadth.** A completely working consensus engine with correct multi-tenant isolation beats 8 half-finished features.
