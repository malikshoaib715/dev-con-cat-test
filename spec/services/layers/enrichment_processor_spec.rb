require "rails_helper"

RSpec.describe Layers::EnrichmentProcessor do
  before { load_layer_fixtures(described_class.layer_key) }

  it "belongs to the enrichment layer" do
    expect(described_class.layer_key).to eq("enrichment")
  end

  # L-1002: neither source can find this person. Nobody to cross-validate.
  describe "an identity neither source can match to the lead (L-1002)" do
    let(:outcome) { process_fixture_lead("L-1002") }

    it "warns and says nothing matched" do
      expect(outcome.verdict).to eq("no_match_to_lead")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq("neither source could match this identity to the lead")
      expect(outcome.signals).to eq([ "no_match_to_lead" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  # L-1011: two sources return two different addresses and two different age bands
  # for one person. Cross-validation is exactly what catches this.
  describe "sources that return different people (L-1011)" do
    let(:outcome) { process_fixture_lead("L-1011") }

    it "warns and names the fields they disagree on" do
      expect(outcome.verdict).to eq("sources_disagree")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq("AudienceLabs and ByteMine disagree on address and age band")
      expect(outcome.signals).to eq([ "sources_disagree" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  # L-1009: one source resolved a person, the other resolved nothing. Coverage
  # without corroboration weighs the same as contradiction.
  describe "an identity only one source can resolve (L-1009)" do
    let(:outcome) { process_fixture_lead("L-1009") }

    it "warns and says which source stood alone" do
      expect(outcome.verdict).to eq("sources_disagree")
      expect(outcome.detail).to eq(
        "only AudienceLabs could resolve this identity — single-source coverage"
      )
      expect(outcome.signals).to eq([ "sources_disagree" ])
    end
  end

  describe "two sources agreeing on a person who matches the lead (L-1001)" do
    let(:outcome) { process_fixture_lead("L-1001") }

    it "passes with the wording the panel already shows" do
      expect(outcome.verdict).to eq("match")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to eq("2 sources agree, identity matches")
      expect(outcome.signals).to be_empty
    end
  end

  # The clean default has no address or age band for either source, which is
  # agreement about nothing rather than a disagreement.
  it "does not read two empty answers as a contradiction" do
    outcome = process_payload({
      "audiencelabs" => { "matched" => true, "address" => nil, "age_band" => nil, "match_to_lead" => true },
      "bytemine" => { "matched" => true, "address" => nil, "age_band" => nil, "match_to_lead" => true }
    })

    expect(outcome.verdict).to eq("match")
    expect(outcome.panel_verdict).to eq("pass")
  end
end
