require Rails.root.join("db/seeds/mock_data")
require Rails.root.join("db/seeds/layer_definitions")
require Rails.root.join("db/seeds/accounts")
require Rails.root.join("db/seeds/users")
require Rails.root.join("db/seeds/layer_policies")
require Rails.root.join("db/seeds/pixels")
require Rails.root.join("db/seeds/provider_responses")

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

  def load_provider_responses(layer_keys: Seeds::ProviderResponses::VENDOR_LAYER_KEYS)
    without_stdout { Seeds::ProviderResponses.load!(layer_keys: layer_keys) }
  end

  # What a single layer's processor needs and no more: the fixture accounts and
  # pixels its personas belong to, the seeded weights, and that one provider's
  # recorded answers. Loading all nine providers and every user per example costs
  # the suite more than it proves.
  def load_layer_fixtures(layer_key)
    without_stdout do
      Seeds::LayerDefinitions.load!
      Seeds::Accounts.load!
      Seeds::LayerPolicies.load!
      Seeds::Pixels.load!
      Seeds::ProviderResponses.load!(layer_keys: [ layer_key ]) if layer_key.in?(Seeds::ProviderResponses::VENDOR_LAYER_KEYS)
    end
  end

  # A lead built from one of the twelve fixture personas, carrying the same
  # identity and public id the provider fixtures are keyed by.
  def fixture_lead(lead_ref, account: nil, **overrides)
    attributes = Seeds::MockData.read("leads.json").fetch("leads").find { |lead| lead["lead_id"] == lead_ref }
    raise ArgumentError, "no fixture lead #{lead_ref}" if attributes.nil?

    account ||= fixture_account(attributes.fetch("account_id"))
    as_tenant(account) do
      create(:lead, **fixture_lead_attributes(attributes, account), **overrides)
    end
  end

  def fixture_lead_attributes(attributes, account)
    {
      account: account,
      pixel: fixture_pixel_for(account) || create(:pixel, account: account),
      public_id: attributes.fetch("lead_id"),
      first_name: attributes.fetch("first_name"),
      last_name: attributes.fetch("last_name"),
      email: attributes.fetch("email"),
      email_normalized: Leads::Normalizer.email(attributes.fetch("email")),
      phone: attributes.fetch("phone"),
      phone_normalized: Leads::Normalizer.phone(attributes.fetch("phone")),
      ip_address: attributes.fetch("ip_address"),
      user_agent: attributes.fetch("user_agent"),
      page_url: attributes.fetch("landing_page_url"),
      form_dwell_ms: attributes.fetch("form_dwell_ms"),
      submitted_at: attributes.fetch("captured_at")
    }
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
