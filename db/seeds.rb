# Idempotent: every step is keyed on the fixtures' own identifiers, so re-running
# `bin/rails db:seed` updates in place rather than duplicating.
#
# Order matters. Layer definitions describe the policy the accounts are billed
# against; policies decide what each account pays for; pixels advertise the
# intersection. The twelve leads run last but one, through the real ingestion
# service and the real pipeline, and the balances are reconciled after them.

require_relative "seeds/mock_data"
require_relative "seeds/layer_definitions"
require_relative "seeds/accounts"
require_relative "seeds/users"
require_relative "seeds/layer_policies"
require_relative "seeds/pixels"
require_relative "seeds/provider_responses"
require_relative "seeds/crm_records"
require_relative "seeds/leads"
require_relative "seeds/balance_reconciliation"

puts "Seeding from mock-data/ ..."

Seeds::LayerDefinitions.load!
Seeds::Accounts.load!
Seeds::Users.load!
Seeds::LayerPolicies.load!
Seeds::Pixels.load!
Seeds::ProviderResponses.load!
Seeds::CrmRecords.load!
Seeds::Leads.load!
Seeds::BalanceReconciliation.load!

rows = Seeds::Leads.report

puts
puts "Verdicts derived by the engine, against the fixtures' hints:"
puts format("  %-8s %-8s %-6s %-17s %-16s %-52s %s",
            "Lead", "Derived", "Score", "Hint", "Flags", "Via", "")
rows.each do |row|
  puts format("  %-8s %-8s %-6d %-17s %-16s %-52s %s",
              row.lead_ref, row.derived, row.score, row.hint, row.flags.join(","),
              row.via.to_s.truncate(52), row.matches? ? "match" : "MISMATCH")
end
puts "  #{rows.count(&:matches?)}/#{rows.size} match the fixture hints"

puts
puts "Credit balances, against accounts.json:"
Account.ordered_by_name.each do |account|
  ActsAsTenant.with_tenant(account) do
    purchased = account.layer_policies.enabled.pluck(:layer_key)
    cost = LayerDefinition.where(key: purchased).sum(:cost_credits)
    ledger = account.credit_ledger_entries.sum(:amount)
    puts format("  %-22s balance %-8d ledger %-8d %2d credits/run",
                account.public_id, account.credit_balance, ledger, cost)
  end
end

puts
puts "Sign-in credentials (placeholders from mock-data/users.json):"
Seeds::Users.credentials_table.each do |email, password, role|
  puts format("  %-36s %-22s %s", email, password, role)
end
