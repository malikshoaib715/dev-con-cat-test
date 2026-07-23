require Rails.root.join("db/seeds/mock_data")
require Rails.root.join("db/seeds/layer_definitions")
require Rails.root.join("db/seeds/accounts")
require Rails.root.join("db/seeds/users")
require Rails.root.join("db/seeds/layer_policies")
require Rails.root.join("db/seeds/pixels")

# Several specs need the real fixture accounts rather than factory ones, because
# the arithmetic under test (cost per run, credit balances, which layers an
# account actually bought) is the fixtures' arithmetic.
module SeedLoading
  FIXTURE_ACCOUNT_IDS = %w[acct_solarpro acct_medicareedge acct_autoinsure].freeze

  # Costs per run, derived from `module_costs_in_credits` x each account's
  # `enabled_modules` in mock-data/accounts.json.
  COST_PER_RUN = { "acct_solarpro" => 17, "acct_medicareedge" => 21, "acct_autoinsure" => 8 }.freeze

  def load_static_seeds
    without_stdout do
      Seeds::LayerDefinitions.load!
      Seeds::Accounts.load!
      Seeds::Users.load!
      Seeds::LayerPolicies.load!
      Seeds::Pixels.load!
    end
  end

  def load_layer_definitions
    without_stdout { Seeds::LayerDefinitions.load! }
  end

  def fixture_account(public_id)
    Account.find_by!(public_id: public_id)
  end

  def fixture_pixel_for(account)
    as_tenant(account) { Pixel.ordered.first }
  end
end

RSpec.configure do |config|
  config.include SeedLoading
end
