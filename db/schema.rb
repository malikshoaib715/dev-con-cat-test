# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_26_040001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.string "billing_email", null: false
    t.datetime "created_at", null: false
    t.integer "credit_balance", default: 0, null: false
    t.date "cycle_end", null: false
    t.date "cycle_start", null: false
    t.integer "monthly_credit_allowance", default: 0, null: false
    t.string "name", null: false
    t.string "plan", null: false
    t.string "public_id", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_accounts_on_public_id", unique: true
    t.index ["status"], name: "index_accounts_on_status"
    t.check_constraint "credit_balance >= 0", name: "accounts_credit_balance_non_negative"
    t.check_constraint "plan::text = ANY (ARRAY['starter'::character varying::text, 'growth'::character varying::text, 'enterprise'::character varying::text])", name: "accounts_plan_valid"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'past_due'::character varying::text, 'suspended'::character varying::text])", name: "accounts_status_valid"
  end

  create_table "audit_events", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "actor_id"
    t.string "actor_type", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "ip_address"
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "request_id"
    t.string "session_id"
    t.bigint "subject_id"
    t.string "subject_type"
    t.index ["account_id", "event_type", "occurred_at"], name: "idx_on_account_id_event_type_occurred_at_9665c907b6"
    t.index ["account_id", "occurred_at"], name: "index_audit_events_on_account_id_and_occurred_at"
    t.index ["event_type", "occurred_at"], name: "index_audit_events_on_event_type_and_occurred_at"
    t.index ["payload"], name: "index_audit_events_on_payload", using: :gin
    t.index ["session_id"], name: "index_audit_events_on_session_id"
    t.index ["subject_type", "subject_id", "occurred_at"], name: "idx_on_subject_type_subject_id_occurred_at_92d4f006a6"
  end

  create_table "consensus_verdicts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "flags", default: [], null: false
    t.string "hard_stop_layer"
    t.datetime "issued_at", null: false
    t.jsonb "policy_snapshot", default: {}, null: false
    t.jsonb "reasons", default: [], null: false
    t.integer "score", null: false
    t.datetime "updated_at", null: false
    t.string "verdict", null: false
    t.bigint "verification_run_id", null: false
    t.index ["account_id", "verdict"], name: "index_consensus_verdicts_on_account_id_and_verdict"
    t.index ["verification_run_id"], name: "index_consensus_verdicts_on_verification_run_id", unique: true
    t.check_constraint "score >= 0 AND score <= 100", name: "consensus_verdicts_score_in_range"
    t.check_constraint "verdict::text = ANY (ARRAY['accept'::character varying::text, 'review'::character varying::text, 'reject'::character varying::text])", name: "consensus_verdicts_verdict_valid"
  end

  create_table "consent_certificates", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "evidence", default: {}, null: false
    t.string "evidence_hash", null: false
    t.datetime "issued_at", null: false
    t.bigint "lead_id", null: false
    t.string "previous_hash"
    t.string "public_id", null: false
    t.integer "sequence_number", null: false
    t.string "trustedform_reference"
    t.string "verdict", null: false
    t.bigint "verification_run_id", null: false
    t.index ["account_id", "issued_at"], name: "index_consent_certificates_on_account_id_and_issued_at"
    t.index ["account_id", "sequence_number"], name: "index_consent_certificates_on_account_id_and_sequence_number", unique: true
    t.index ["public_id"], name: "index_consent_certificates_on_public_id", unique: true
    t.index ["verification_run_id"], name: "index_consent_certificates_on_verification_run_id", unique: true
    t.check_constraint "verdict::text = ANY (ARRAY['accept'::character varying::text, 'review'::character varying::text, 'reject'::character varying::text])", name: "consent_certificates_verdict_valid"
  end

  create_table "credit_ledger_entries", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.integer "amount", null: false
    t.integer "balance_after", null: false
    t.jsonb "breakdown", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "entry_type", null: false
    t.string "memo"
    t.bigint "verification_run_id"
    t.index ["account_id", "created_at"], name: "index_credit_ledger_entries_on_account_id_and_created_at"
    t.index ["account_id", "entry_type", "created_at"], name: "idx_on_account_id_entry_type_created_at_e9835cb2a1"
    t.index ["verification_run_id", "entry_type"], name: "index_ledger_on_run_and_type_when_run_present", unique: true, where: "(verification_run_id IS NOT NULL)"
    t.check_constraint "entry_type::text = ANY (ARRAY['grant'::character varying::text, 'reservation'::character varying::text, 'settlement_refund'::character varying::text, 'adjustment'::character varying::text])", name: "credit_ledger_entries_type_valid"
  end

  create_table "crm_records", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.string "email"
    t.string "email_normalized"
    t.string "external_ref", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "phone"
    t.string "phone_normalized"
    t.datetime "source_created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "email_normalized"], name: "index_crm_records_on_account_id_and_email_normalized"
    t.index ["account_id", "external_ref"], name: "index_crm_records_on_account_id_and_external_ref", unique: true
    t.index ["account_id", "phone_normalized"], name: "index_crm_records_on_account_id_and_phone_normalized"
  end

  create_table "layer_definitions", force: :cascade do |t|
    t.integer "cost_credits", null: false
    t.datetime "created_at", null: false
    t.string "criticality", null: false
    t.jsonb "default_weights", default: {}, null: false
    t.boolean "hard_stop_capable", default: false, null: false
    t.string "key", null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_layer_definitions_on_key", unique: true
    t.index ["position"], name: "index_layer_definitions_on_position", unique: true
    t.check_constraint "cost_credits >= 0", name: "layer_definitions_cost_non_negative"
    t.check_constraint "criticality::text = ANY (ARRAY['required'::character varying::text, 'optional'::character varying::text])", name: "layer_definitions_criticality_valid"
    t.check_constraint "key::text = ANY (ARRAY['vpn_proxy'::character varying::text, 'anura'::character varying::text, 'trustedform'::character varying::text, 'blacklist_alliance'::character varying::text, 'dnc'::character varying::text, 'phone_validation'::character varying::text, 'email_validation'::character varying::text, 'enrichment'::character varying::text, 'duplicate_detection'::character varying::text, 'voice'::character varying::text])", name: "layer_definitions_key_canonical"
  end

  create_table "layer_policies", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "layer_key", null: false
    t.boolean "treat_as_hard_stop", default: false, null: false
    t.datetime "updated_at", null: false
    t.jsonb "weight_overrides", default: {}, null: false
    t.index ["account_id", "layer_key"], name: "index_layer_policies_on_account_id_and_layer_key", unique: true
    t.check_constraint "layer_key::text = ANY (ARRAY['vpn_proxy'::character varying::text, 'anura'::character varying::text, 'trustedform'::character varying::text, 'blacklist_alliance'::character varying::text, 'dnc'::character varying::text, 'phone_validation'::character varying::text, 'email_validation'::character varying::text, 'enrichment'::character varying::text, 'duplicate_detection'::character varying::text, 'voice'::character varying::text])", name: "layer_policies_layer_key_canonical"
  end

  create_table "layer_results", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "detail"
    t.string "error_class"
    t.string "error_message"
    t.string "layer_key", null: false
    t.string "panel_verdict"
    t.jsonb "raw_response", default: {}, null: false
    t.integer "score_delta"
    t.datetime "started_at"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.string "verdict"
    t.bigint "verification_run_id", null: false
    t.index ["account_id", "layer_key", "status"], name: "index_layer_results_on_account_id_and_layer_key_and_status"
    t.index ["verification_run_id", "layer_key"], name: "index_layer_results_on_verification_run_id_and_layer_key", unique: true
    t.index ["verification_run_id", "status"], name: "index_layer_results_on_verification_run_id_and_status"
    t.check_constraint "layer_key::text = ANY (ARRAY['vpn_proxy'::character varying::text, 'anura'::character varying::text, 'trustedform'::character varying::text, 'blacklist_alliance'::character varying::text, 'dnc'::character varying::text, 'phone_validation'::character varying::text, 'email_validation'::character varying::text, 'enrichment'::character varying::text, 'duplicate_detection'::character varying::text, 'voice'::character varying::text])", name: "layer_results_layer_key_canonical"
    t.check_constraint "panel_verdict IS NULL OR (panel_verdict::text = ANY (ARRAY['pass'::character varying::text, 'warn'::character varying::text, 'fail'::character varying::text, 'skip'::character varying::text]))", name: "layer_results_panel_verdict_valid"
    t.check_constraint "status::text = ANY (ARRAY['not_enabled'::character varying::text, 'not_applicable'::character varying::text, 'pending'::character varying::text, 'processing'::character varying::text, 'completed'::character varying::text, 'errored'::character varying::text])", name: "layer_results_status_valid"
  end

  create_table "leads", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.string "email"
    t.string "email_normalized"
    t.string "first_name"
    t.jsonb "flags", default: [], null: false
    t.integer "form_dwell_ms"
    t.string "ip_address"
    t.string "last_name"
    t.string "page_url"
    t.string "phone"
    t.string "phone_normalized"
    t.bigint "pixel_id", null: false
    t.string "public_id", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.string "session_id", null: false
    t.string "status", default: "received", null: false
    t.datetime "submitted_at", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.string "verdict"
    t.index ["account_id", "created_at"], name: "index_leads_on_account_id_and_created_at"
    t.index ["account_id", "email_normalized"], name: "index_leads_on_account_id_and_email_normalized"
    t.index ["account_id", "phone_normalized"], name: "index_leads_on_account_id_and_phone_normalized"
    t.index ["account_id", "status"], name: "index_leads_on_account_id_and_status"
    t.index ["account_id", "verdict"], name: "index_leads_on_account_id_and_verdict"
    t.index ["pixel_id", "session_id"], name: "index_leads_on_pixel_id_and_session_id", unique: true
    t.index ["public_id"], name: "index_leads_on_public_id", unique: true
    t.check_constraint "status::text = ANY (ARRAY['received'::character varying::text, 'verifying'::character varying::text, 'on_hold_insufficient_credits'::character varying::text, 'completed'::character varying::text])", name: "leads_status_valid"
    t.check_constraint "verdict IS NULL OR (verdict::text = ANY (ARRAY['accept'::character varying::text, 'review'::character varying::text, 'reject'::character varying::text]))", name: "leads_verdict_valid"
  end

  create_table "pixels", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "active", default: true, null: false
    t.string "allowed_domains", default: [], null: false, array: true
    t.datetime "created_at", null: false
    t.string "enabled_layers", default: [], null: false, array: true
    t.string "name", null: false
    t.string "public_id", null: false
    t.string "public_key", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "index_pixels_on_account_id_and_created_at"
    t.index ["account_id"], name: "index_pixels_on_account_id"
    t.index ["public_id"], name: "index_pixels_on_public_id", unique: true
    t.index ["public_key"], name: "index_pixels_on_public_key", unique: true
  end

  create_table "provider_responses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_normalized"
    t.string "layer_key", null: false
    t.string "lead_ref"
    t.jsonb "payload", default: {}, null: false
    t.string "phone_normalized"
    t.datetime "updated_at", null: false
    t.index ["layer_key", "email_normalized"], name: "index_provider_responses_on_layer_key_and_email_normalized"
    t.index ["layer_key", "lead_ref"], name: "index_provider_responses_on_layer_key_and_lead_ref", unique: true
    t.index ["layer_key", "phone_normalized"], name: "index_provider_responses_on_layer_key_and_phone_normalized"
    t.check_constraint "layer_key::text = ANY (ARRAY['vpn_proxy'::character varying::text, 'anura'::character varying::text, 'trustedform'::character varying::text, 'blacklist_alliance'::character varying::text, 'dnc'::character varying::text, 'phone_validation'::character varying::text, 'email_validation'::character varying::text, 'enrichment'::character varying::text, 'duplicate_detection'::character varying::text, 'voice'::character varying::text])", name: "provider_responses_layer_key_canonical"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "name", null: false
    t.datetime "remember_created_at"
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "role"], name: "index_users_on_account_id_and_role"
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.check_constraint "role::text = 'super_admin'::text AND account_id IS NULL OR role::text <> 'super_admin'::text AND account_id IS NOT NULL", name: "users_account_matches_role"
    t.check_constraint "role::text = ANY (ARRAY['super_admin'::character varying::text, 'account_admin'::character varying::text, 'member'::character varying::text])", name: "users_role_valid"
  end

  create_table "verification_runs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "lead_id", null: false
    t.integer "reserved_credits", default: 0, null: false
    t.integer "settled_credits"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"], name: "index_verification_runs_on_account_id_and_status"
    t.index ["lead_id"], name: "index_verification_runs_on_lead_id", unique: true
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'finalizing'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "verification_runs_status_valid"
  end

  create_table "visits", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "interactions", default: [], null: false
    t.string "ip_address"
    t.string "page_url"
    t.bigint "pixel_id", null: false
    t.string "referrer"
    t.string "session_id", null: false
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["account_id", "started_at"], name: "index_visits_on_account_id_and_started_at"
    t.index ["pixel_id", "session_id"], name: "index_visits_on_pixel_id_and_session_id", unique: true
  end

  add_foreign_key "consensus_verdicts", "accounts"
  add_foreign_key "consensus_verdicts", "verification_runs"
  add_foreign_key "consent_certificates", "accounts"
  add_foreign_key "consent_certificates", "leads"
  add_foreign_key "consent_certificates", "verification_runs"
  add_foreign_key "credit_ledger_entries", "accounts"
  add_foreign_key "credit_ledger_entries", "verification_runs"
  add_foreign_key "crm_records", "accounts"
  add_foreign_key "layer_policies", "accounts"
  add_foreign_key "layer_results", "accounts"
  add_foreign_key "layer_results", "verification_runs"
  add_foreign_key "leads", "accounts"
  add_foreign_key "leads", "pixels"
  add_foreign_key "pixels", "accounts"
  add_foreign_key "users", "accounts"
  add_foreign_key "verification_runs", "accounts"
  add_foreign_key "verification_runs", "leads"
  add_foreign_key "visits", "accounts"
  add_foreign_key "visits", "pixels"
end
