require "rails_helper"

RSpec.describe Layers::BlacklistAllianceProcessor do
  before { load_layer_fixtures(described_class.layer_key) }

  it "belongs to the blacklist_alliance layer" do
    expect(described_class.layer_key).to eq("blacklist_alliance")
  end

  # L-1005: a phone tied to fourteen filed TCPA complaints. The most expensive
  # lead a buyer could dial.
  describe "a confirmed serial litigator (L-1005)" do
    let(:outcome) { process_fixture_lead("L-1005") }

    it "fails the layer and cites the score and the sources" do
      expect(outcome.verdict).to eq("litigator")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to eq(
        "confirmed litigator, match score 97 (tcpa_complaint_db, attorney_of_record_index)"
      )
      expect(outcome.signals).to be_empty
    end
  end

  # L-1011: a loose pattern match. Weighted, not fatal — a buyer who wants it
  # fatal flips treat_as_hard_stop without a deploy.
  describe "a suspected but unconfirmed match (L-1011)" do
    let(:outcome) { process_fixture_lead("L-1011") }

    it "warns and is left to the score" do
      expect(outcome.verdict).to eq("suspected")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq("pattern watchlist, not confirmed — match score 58 (pattern_watchlist)")
      expect(outcome.signals).to eq([ "suspected" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  describe "no match at all (L-1001)" do
    let(:outcome) { process_fixture_lead("L-1001") }

    it "passes with nothing to score" do
      expect(outcome.verdict).to eq("clean")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to eq("no litigator match")
      expect(outcome.signals).to be_empty
    end
  end

  # L-1007 scores 3 against the watchlist and is still reported clean: a non-zero
  # score is not a match.
  it "does not treat a low score on a clean status as a hit (L-1007)" do
    expect(process_fixture_lead("L-1007").verdict).to eq("clean")
  end

  it "reads a hit with no named sources without trailing punctuation" do
    outcome = process_payload({ "status" => "litigator", "match_score" => 88, "sources" => [] })

    expect(outcome.detail).to eq("confirmed litigator, match score 88")
  end
end
