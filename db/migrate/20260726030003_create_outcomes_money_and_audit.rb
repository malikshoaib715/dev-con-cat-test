class CreateOutcomesMoneyAndAudit < ActiveRecord::Migration[8.1]
  def change
    create_table :consensus_verdicts do |t|
      t.references :account,          null: false, foreign_key: true, index: false
      t.references :verification_run, null: false, foreign_key: true, index: false
      t.string   :verdict,          null: false
      t.integer  :score,            null: false
      t.jsonb    :reasons,          null: false, default: []
      t.jsonb    :flags,            null: false, default: []
      t.string   :hard_stop_layer
      # The exact weights and thresholds that produced this verdict, so it stays
      # explainable after a buyer retunes their policy.
      t.jsonb    :policy_snapshot,  null: false, default: {}
      t.datetime :issued_at,        null: false

      t.timestamps
    end
    add_index :consensus_verdicts, :verification_run_id, unique: true
    add_index :consensus_verdicts, [ :account_id, :verdict ]

    add_check_constraint :consensus_verdicts, "verdict IN ('accept', 'review', 'reject')", name: "consensus_verdicts_verdict_valid"
    add_check_constraint :consensus_verdicts, "score BETWEEN 0 AND 100", name: "consensus_verdicts_score_in_range"

    create_table :consent_certificates do |t|
      t.references :account,          null: false, foreign_key: true, index: false
      t.references :lead,             null: false, foreign_key: true, index: false
      t.references :verification_run, null: false, foreign_key: true, index: false
      t.string   :public_id,               null: false
      t.string   :verdict,                 null: false
      t.jsonb    :evidence,                null: false, default: {}
      t.string   :evidence_hash,           null: false
      t.string   :previous_hash
      t.integer  :sequence_number,         null: false
      t.string   :trustedform_reference
      t.datetime :issued_at,               null: false

      # Append-only by design: no updated_at, and the model is readonly after create.
      t.datetime :created_at, null: false
    end
    add_index :consent_certificates, :public_id, unique: true
    add_index :consent_certificates, :verification_run_id, unique: true
    # Per-account hash chain: gapless sequence, each link naming its predecessor.
    add_index :consent_certificates, [ :account_id, :sequence_number ], unique: true
    add_index :consent_certificates, [ :account_id, :issued_at ]

    create_table :credit_ledger_entries do |t|
      t.references :account,          null: false, foreign_key: true, index: false
      t.references :verification_run, foreign_key: true, index: false
      t.string   :entry_type,    null: false
      t.integer  :amount,        null: false
      t.integer  :balance_after, null: false
      t.jsonb    :breakdown,     null: false, default: {}
      t.string   :memo

      t.datetime :created_at, null: false
    end
    add_index :credit_ledger_entries, [ :account_id, :created_at ]
    add_index :credit_ledger_entries, [ :account_id, :entry_type, :created_at ]
    # A retried job can never double-charge or double-refund a run.
    add_index :credit_ledger_entries,
              [ :verification_run_id, :entry_type ],
              unique: true,
              where: "verification_run_id IS NOT NULL",
              name: "index_ledger_on_run_and_type_when_run_present"

    add_check_constraint :credit_ledger_entries,
                         "entry_type IN ('grant', 'reservation', 'settlement_refund', 'adjustment')",
                         name: "credit_ledger_entries_type_valid"

    create_table :audit_events do |t|
      t.references :account, index: false          # nullable: platform-level events have no tenant
      t.string   :event_type,   null: false
      t.string   :actor_type,   null: false
      t.bigint   :actor_id
      t.string   :subject_type
      t.bigint   :subject_id
      t.string   :request_id
      t.string   :session_id
      t.string   :ip_address
      t.jsonb    :payload,      null: false, default: {}
      t.datetime :occurred_at,  null: false

      t.datetime :created_at, null: false
    end
    add_index :audit_events, [ :account_id, :occurred_at ]
    add_index :audit_events, [ :account_id, :event_type, :occurred_at ]
    add_index :audit_events, [ :subject_type, :subject_id, :occurred_at ]
    add_index :audit_events, [ :event_type, :occurred_at ]
    add_index :audit_events, :session_id
    add_index :audit_events, :payload, using: :gin

    create_table :crm_records do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.string   :external_ref,      null: false
      t.string   :first_name
      t.string   :last_name
      t.string   :email
      t.string   :email_normalized
      t.string   :phone
      t.string   :phone_normalized
      t.datetime :source_created_at, null: false

      t.timestamps
    end
    add_index :crm_records, [ :account_id, :external_ref ], unique: true
    add_index :crm_records, [ :account_id, :phone_normalized ]
    add_index :crm_records, [ :account_id, :email_normalized ]

    # The seeded vendor fixture store behind Providers::Gateway. Not tenant-owned:
    # a provider's answer about an identity is the same whoever asks.
    create_table :provider_responses do |t|
      t.string :layer_key,        null: false
      t.string :lead_ref
      t.string :email_normalized
      t.string :phone_normalized
      t.jsonb  :payload,          null: false, default: {}

      t.timestamps
    end
    add_index :provider_responses, [ :layer_key, :lead_ref ], unique: true
    add_index :provider_responses, [ :layer_key, :phone_normalized ]
    add_index :provider_responses, [ :layer_key, :email_normalized ]
  end
end
