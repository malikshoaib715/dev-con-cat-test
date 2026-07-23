# Idempotent: every step is keyed on the fixtures' own identifiers, so re-running
# `bin/rails db:seed` updates in place rather than duplicating.
#
# Order matters. Layer definitions describe the policy the accounts are billed
# against; policies decide what each account pays for; pixels advertise the
# intersection.

require_relative "seeds/mock_data"
require_relative "seeds/layer_definitions"
require_relative "seeds/accounts"
require_relative "seeds/users"
require_relative "seeds/layer_policies"
require_relative "seeds/pixels"
require_relative "seeds/provider_responses"

puts "Seeding from mock-data/ ..."

Seeds::LayerDefinitions.load!
Seeds::Accounts.load!
Seeds::Users.load!
Seeds::LayerPolicies.load!
Seeds::Pixels.load!
Seeds::ProviderResponses.load!

puts
puts "Credit cost per verification run, by account:"
Account.ordered_by_name.each do |account|
  ActsAsTenant.with_tenant(account) do
    purchased = account.layer_policies.enabled.pluck(:layer_key)
    cost = LayerDefinition.where(key: purchased).sum(:cost_credits)
    puts format("  %-22s %2d credits/run   balance %d", account.public_id, cost, account.credit_balance)
  end
end

puts
puts "Sign-in credentials (placeholders from mock-data/users.json):"
Seeds::Users.credentials_table.each do |email, password, role|
  puts format("  %-36s %-22s %s", email, password, role)
end
