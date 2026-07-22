require "rails_helper"

RSpec.describe LayerDefinition do
  it "accepts only canonical layer keys" do
    expect(build(:layer_definition, key: "voice_ai")).not_to be_valid
    expect(build(:layer_definition, key: "voice", position: 10)).to be_valid
  end

  it "keeps the key and the panel position unique, so no two layers collide" do
    create(:layer_definition, key: "anura", position: 2)

    expect(build(:layer_definition, key: "anura", position: 99)).not_to be_valid
    expect(build(:layer_definition, key: "dnc", position: 2)).not_to be_valid
  end

  it "refuses a negative cost" do
    expect(build(:layer_definition, cost_credits: -1)).not_to be_valid
  end

  it "speaks only the two criticalities that decide fail-open versus fail-closed" do
    expect(described_class::CRITICALITIES).to eq(%w[required optional])
    expect(build(:layer_definition, criticality: "nice_to_have")).not_to be_valid
  end

  describe "#fail_closed?" do
    it "caps the verdict when a compliance layer could not answer" do
      expect(build(:layer_definition, criticality: "required")).to be_fail_closed
    end

    it "lets an optional layer fail open so one flaky vendor cannot bury a good lead" do
      expect(build(:layer_definition, criticality: "optional")).not_to be_fail_closed
    end
  end

  it "orders by panel position rather than insertion order" do
    second = create(:layer_definition, key: "dnc", position: 5)
    first  = create(:layer_definition, key: "anura", position: 2)

    expect(described_class.ordered.to_a).to eq([ first, second ])
  end

  it "carries the score deltas as data, so a buyer can retune without a deploy" do
    definition = create(:layer_definition, key: "anura", position: 2,
                                           default_weights: { "suspect" => -15, "suspect_fraud_farm" => -50 })

    expect(definition.reload.default_weights).to eq("suspect" => -15, "suspect_fraud_farm" => -50)
  end
end
