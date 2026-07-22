class CreateIngestionPipeline < ActiveRecord::Migration[8.1]
  def change
    create_table :visits do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :pixel,   null: false, foreign_key: true, index: false
      t.string   :session_id,   null: false
      t.string   :ip_address
      t.string   :user_agent
      t.string   :page_url
      t.string   :referrer
      t.datetime :started_at,   null: false
      t.jsonb    :interactions, null: false, default: []

      t.timestamps
    end
    # One visit row per capture session: a re-fired beacon updates rather than
    # duplicating, which keeps visit-IP vs submit-IP comparison unambiguous.
    add_index :visits, [ :pixel_id, :session_id ], unique: true
    add_index :visits, [ :account_id, :started_at ]

    create_table :leads do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :pixel,   null: false, foreign_key: true, index: false
      t.string   :public_id,        null: false
      t.string   :first_name
      t.string   :last_name
      t.string   :email
      t.string   :email_normalized
      t.string   :phone
      t.string   :phone_normalized
      t.string   :ip_address
      t.string   :user_agent
      t.string   :page_url
      t.string   :session_id,       null: false
      t.integer  :form_dwell_ms
      t.string   :status,           null: false, default: "received"
      t.string   :verdict
      t.jsonb    :flags,            null: false, default: []
      t.jsonb    :raw_payload,      null: false, default: {}
      t.datetime :submitted_at,     null: false

      t.timestamps
    end
    add_index :leads, :public_id, unique: true
    # Replay defence: the same pixel + client session can only ever produce one
    # lead, so a retried POST returns the original instead of double-charging.
    add_index :leads, [ :pixel_id, :session_id ], unique: true
    add_index :leads, [ :account_id, :created_at ]
    add_index :leads, [ :account_id, :status ]
    add_index :leads, [ :account_id, :verdict ]
    add_index :leads, [ :account_id, :email_normalized ]
    add_index :leads, [ :account_id, :phone_normalized ]

    add_check_constraint :leads,
                         "status IN ('received', 'verifying', 'on_hold_insufficient_credits', 'completed')",
                         name: "leads_status_valid"
    add_check_constraint :leads,
                         "verdict IS NULL OR verdict IN ('accept', 'review', 'reject')",
                         name: "leads_verdict_valid"

    create_table :verification_runs do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :lead,    null: false, foreign_key: true, index: false
      t.string   :status,           null: false, default: "pending"
      t.datetime :started_at
      t.datetime :completed_at
      t.integer  :reserved_credits, null: false, default: 0
      t.integer  :settled_credits

      t.timestamps
    end
    # One run per lead in v1; a re-verification creates a new lead version.
    add_index :verification_runs, :lead_id, unique: true
    add_index :verification_runs, [ :account_id, :status ]

    add_check_constraint :verification_runs,
                         "status IN ('pending', 'running', 'finalizing', 'completed', 'failed')",
                         name: "verification_runs_status_valid"

    create_table :layer_results do |t|
      t.references :account,           null: false, foreign_key: true, index: false
      t.references :verification_run,  null: false, foreign_key: true, index: false
      t.string   :layer_key,     null: false
      t.string   :status,        null: false
      t.string   :verdict
      t.string   :panel_verdict
      t.string   :detail
      t.integer  :score_delta
      t.jsonb    :raw_response,  null: false, default: {}
      t.string   :error_class
      t.string   :error_message
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end
    # Idempotency backstop: a retried layer job cannot create a second row.
    add_index :layer_results, [ :verification_run_id, :layer_key ], unique: true
    # Drives the "is anything still outstanding?" check before finalization.
    add_index :layer_results, [ :verification_run_id, :status ]
    add_index :layer_results, [ :account_id, :layer_key, :status ]

    add_check_constraint :layer_results,
                         "status IN ('not_enabled', 'not_applicable', 'pending', 'processing', 'completed', 'errored')",
                         name: "layer_results_status_valid"
    add_check_constraint :layer_results,
                         "panel_verdict IS NULL OR panel_verdict IN ('pass', 'warn', 'fail', 'skip')",
                         name: "layer_results_panel_verdict_valid"
  end
end
