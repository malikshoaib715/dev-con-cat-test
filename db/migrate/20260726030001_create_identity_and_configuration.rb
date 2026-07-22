class CreateIdentityAndConfiguration < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string  :public_id,                null: false
      t.string  :name,                     null: false
      t.string  :plan,                     null: false
      t.string  :status,                   null: false, default: "active"
      t.integer :credit_balance,           null: false, default: 0
      t.integer :monthly_credit_allowance, null: false, default: 0
      t.date    :cycle_start,              null: false
      t.date    :cycle_end,                null: false
      t.string  :billing_email,            null: false
      t.jsonb   :settings,                 null: false, default: {}

      t.timestamps
    end
    add_index :accounts, :public_id, unique: true
    add_index :accounts, :status

    # The ledger is the truth and credit_balance is its projection; the database
    # refuses a negative projection even if application code has a bug.
    add_check_constraint :accounts, "credit_balance >= 0", name: "accounts_credit_balance_non_negative"
    add_check_constraint :accounts, "status IN ('active', 'past_due', 'suspended')", name: "accounts_status_valid"
    add_check_constraint :accounts, "plan IN ('starter', 'growth', 'enterprise')", name: "accounts_plan_valid"

    create_table :users do |t|
      t.references :account, foreign_key: true, index: true
      t.string   :email,              null: false
      t.string   :encrypted_password, null: false, default: ""
      t.string   :name,               null: false
      t.string   :role,               null: false
      t.datetime :remember_created_at

      t.timestamps
    end
    add_index :users, :email, unique: true
    add_index :users, [ :account_id, :role ]

    add_check_constraint :users, "role IN ('super_admin', 'account_admin', 'member')", name: "users_role_valid"
    # A super_admin is platform-level and belongs to no tenant; everybody else
    # must belong to exactly one. Enforced here so no code path can invent a
    # tenantless account_admin.
    add_check_constraint :users,
                         "(role = 'super_admin' AND account_id IS NULL) OR (role <> 'super_admin' AND account_id IS NOT NULL)",
                         name: "users_account_matches_role"

    create_table :pixels do |t|
      t.references :account, null: false, foreign_key: true
      t.string  :public_id,       null: false
      t.string  :name,            null: false
      t.string  :public_key,      null: false
      t.string  :allowed_domains, null: false, array: true, default: []
      t.string  :enabled_layers,  null: false, array: true, default: []
      t.boolean :active,          null: false, default: true

      t.timestamps
    end
    add_index :pixels, :public_id,  unique: true
    add_index :pixels, :public_key, unique: true
    add_index :pixels, [ :account_id, :created_at ]

    create_table :layer_definitions do |t|
      t.string  :key,               null: false
      t.string  :name,              null: false
      t.integer :cost_credits,      null: false
      t.boolean :hard_stop_capable, null: false, default: false
      t.string  :criticality,       null: false
      t.jsonb   :default_weights,   null: false, default: {}
      t.integer :position,          null: false

      t.timestamps
    end
    add_index :layer_definitions, :key,      unique: true
    add_index :layer_definitions, :position, unique: true

    add_check_constraint :layer_definitions, "criticality IN ('required', 'optional')", name: "layer_definitions_criticality_valid"
    add_check_constraint :layer_definitions, "cost_credits >= 0", name: "layer_definitions_cost_non_negative"

    create_table :layer_policies do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.string  :layer_key,          null: false
      t.boolean :enabled,            null: false, default: true
      t.boolean :treat_as_hard_stop, null: false, default: false
      t.jsonb   :weight_overrides,   null: false, default: {}

      t.timestamps
    end
    add_index :layer_policies, [ :account_id, :layer_key ], unique: true
  end
end
