require "rails_helper"

# Name drift between the fixtures, the account module lists, the cost table and
# the panel labels is the quietest way to break this system, so the registry is
# checked against the fixtures themselves.
RSpec.describe Layers::Registry do
  let(:fixture_costs) do
    JSON.parse(Rails.root.join("mock-data/accounts.json").read).fetch("module_costs_in_credits")
  end

  it "spells exactly the ten layers the fixtures price" do
    expect(described_class.keys).to match_array(fixture_costs.keys)
  end

  it "spells exactly the layers the fixture accounts buy" do
    purchased = JSON.parse(Rails.root.join("mock-data/accounts.json").read)
                    .fetch("accounts").flat_map { |account| account.fetch("enabled_modules") }.uniq

    expect(purchased - described_class.keys).to be_empty
  end

  it "orders the layers deterministically for the panel" do
    expect(described_class.entries.map(&:position)).to eq((1..10).to_a)
  end

  it "refuses an aliased spelling rather than silently returning nothing" do
    expect(described_class.key?("trusted_form")).to be(false)
    expect { described_class.fetch("voice_ai") }.to raise_error(ArgumentError, /voice_ai/)
  end

  it "maps every layer to a processor class name in the Layers namespace" do
    expect(described_class.entries.map(&:processor_name)).to all(start_with("Layers::"))
  end
end
