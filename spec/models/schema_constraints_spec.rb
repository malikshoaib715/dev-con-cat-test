require "rails_helper"

# The database is the last line of defence: if application code has a bug,
# Postgres refuses the corruption. This spec walks the constraints themselves so
# a column added later without one fails here rather than in production.
RSpec.describe "Schema constraints" do
  def check_constraints_on(table)
    ActiveRecord::Base.connection.check_constraints(table.to_s).index_by(&:name)
  end

  def raw_update(sql)
    ActiveRecord::Base.connection.execute(sql)
  end

  describe "string enums" do
    # Every column whose value is drawn from a fixed vocabulary, and the
    # constraint that pins it.
    GUARDED_ENUMS = {
      accounts: %w[accounts_status_valid accounts_plan_valid],
      users: %w[users_role_valid],
      leads: %w[leads_status_valid leads_verdict_valid],
      verification_runs: %w[verification_runs_status_valid],
      layer_results: %w[layer_results_status_valid layer_results_panel_verdict_valid],
      layer_definitions: %w[layer_definitions_criticality_valid],
      consensus_verdicts: %w[consensus_verdicts_verdict_valid],
      consent_certificates: %w[consent_certificates_verdict_valid],
      credit_ledger_entries: %w[credit_ledger_entries_type_valid]
    }.freeze

    GUARDED_ENUMS.each do |table, expected_constraints|
      it "pins every enum column on #{table} in the database, not only in Ruby" do
        expect(check_constraints_on(table).keys).to include(*expected_constraints)
      end
    end
  end

  describe "the consent certificate verdict" do
    let(:account) { create(:account) }

    it "refuses a verdict outside the consensus vocabulary even through raw SQL" do
      certificate = as_tenant(account) { create(:consent_certificate, account: account) }

      expect { raw_update("UPDATE consent_certificates SET verdict = 'vibes' WHERE id = #{certificate.id}") }
        .to raise_error(ActiveRecord::StatementInvalid, /consent_certificates_verdict_valid/)
    end
  end

  describe "layer keys" do
    # Name drift is the quietest way to break this system: an alias breaks
    # fixture lookup, cost lookup and the panel labels all at once.
    GUARDED_LAYER_KEYS = {
      "layer_definitions" => "layer_definitions_key_canonical",
      "layer_policies" => "layer_policies_layer_key_canonical",
      "layer_results" => "layer_results_layer_key_canonical",
      "provider_responses" => "provider_responses_layer_key_canonical"
    }.freeze

    GUARDED_LAYER_KEYS.each do |table, constraint_name|
      it "constrains #{table} to exactly the canonical registry keys" do
        definition = check_constraints_on(table).fetch(constraint_name).expression
        allowed = definition.scan(/'([a-z_]+)'/).flatten

        expect(allowed).to match_array(Layers::Registry.keys)
      end
    end

    it "refuses an aliased spelling even through raw SQL" do
      account = create(:account)
      result = as_tenant(account) { create(:layer_result, account: account, layer_key: "trustedform") }

      expect { raw_update("UPDATE layer_results SET layer_key = 'trusted_form' WHERE id = #{result.id}") }
        .to raise_error(ActiveRecord::StatementInvalid, /layer_results_layer_key_canonical/)
    end
  end

  describe "money and role invariants" do
    it "refuses a negative credit balance" do
      account = create(:account)

      expect { raw_update("UPDATE accounts SET credit_balance = -1 WHERE id = #{account.id}") }
        .to raise_error(ActiveRecord::StatementInvalid, /accounts_credit_balance_non_negative/)
    end

    it "refuses a platform operator who belongs to a tenant" do
      operator = create(:user, :super_admin)
      account = create(:account)

      expect { raw_update("UPDATE users SET account_id = #{account.id} WHERE id = #{operator.id}") }
        .to raise_error(ActiveRecord::StatementInvalid, /users_account_matches_role/)
    end

    it "refuses a tenant user with no account" do
      account = create(:account)
      member = create(:user, account: account, role: "member")

      expect { raw_update("UPDATE users SET account_id = NULL WHERE id = #{member.id}") }
        .to raise_error(ActiveRecord::StatementInvalid, /users_account_matches_role/)
    end
  end
end
