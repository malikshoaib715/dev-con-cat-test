require "rails_helper"

RSpec.describe Layers::AnuraProcessor do
  before { load_layer_fixtures(described_class.layer_key) }

  it "belongs to the anura layer" do
    expect(described_class.layer_key).to eq("anura")
  end

  # L-1002: datacenter IP, python-requests, sub-second form fill. The engine
  # treats this exact verdict string as a hard stop.
  describe "a confirmed bot (L-1002)" do
    let(:outcome) { process_fixture_lead("L-1002") }

    it "returns the hard-stop verdict with the vendor's reasoning" do
      expect(outcome.verdict).to eq("bad")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to eq(
        "result: bad (bot/malware) — DATACENTER_IP, AUTOMATION_TOOL, FORM_FILL_TOO_FAST"
      )
    end

    # A hard stop forces the score to zero, so weighting it would be arithmetic
    # nobody reads.
    it "emits no weighted signal" do
      expect(outcome.signals).to be_empty
    end
  end

  # L-1009: the same voiceprint and device behind several identities. Suspicion
  # this specific is worth more than a generic one.
  describe "a fraud-farm cluster (L-1009)" do
    let(:outcome) { process_fixture_lead("L-1009") }

    it "fails the layer and says what kind of suspect it is" do
      expect(outcome.verdict).to eq("suspect_fraud_farm")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to eq(
        "result: suspect (fraud-farm cluster) — FRAUD_FARM_CLUSTER, REPEAT_DEVICE_MULTI_IDENTITY"
      )
      expect(outcome.signals).to eq([ "suspect_fraud_farm" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  # L-1003: suspicion because the IP is an anonymizer — a lead to look at, not one
  # to refuse.
  describe "an anonymizer suspect (L-1003)" do
    let(:outcome) { process_fixture_lead("L-1003") }

    it "warns rather than fails" do
      expect(outcome.verdict).to eq("suspect_anonymizer")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq("result: suspect (anonymizer) — ANONYMIZER_IP")
      expect(outcome.signals).to eq([ "suspect_anonymizer" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  # L-1007: suspect with no traffic type at all — the vendor is unsure why.
  describe "an unclassified suspect (L-1007)" do
    let(:outcome) { process_fixture_lead("L-1007") }

    it "carries the weakest of the three suspicions" do
      expect(outcome.verdict).to eq("suspect")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq("result: suspect (unclassified) — DEVICE_REPUTATION_LOW")
      expect(outcome.signals).to eq([ "suspect" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  describe "a real human (L-1001)" do
    let(:outcome) { process_fixture_lead("L-1001") }

    it "passes with nothing to score" do
      expect(outcome.verdict).to eq("good")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to eq("result: good")
      expect(outcome.signals).to be_empty
    end
  end

  it "reads a suspect with no rule ids without inventing reasoning" do
    outcome = process_payload({ "result" => "suspect", "rule_ids" => [], "invalid_traffic_type" => nil })

    expect(outcome.detail).to eq("result: suspect (unclassified)")
  end

  it "treats an unrecognised traffic type as an unclassified suspect" do
    outcome = process_payload({ "result" => "suspect", "rule_ids" => [], "invalid_traffic_type" => "something_new" })

    expect(outcome.verdict).to eq("suspect")
    expect(outcome.panel_verdict).to eq("warn")
  end
end
