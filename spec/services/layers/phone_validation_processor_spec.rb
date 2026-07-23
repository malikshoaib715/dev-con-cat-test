require "rails_helper"

RSpec.describe Layers::PhoneValidationProcessor do
  before { load_layer_fixtures(described_class.layer_key) }

  it "belongs to the phone_validation layer" do
    expect(described_class.layer_key).to eq("phone_validation")
  end

  # L-1002: two of three providers cannot find the number at all.
  describe "a number two providers say is not real (L-1002)" do
    let(:outcome) { process_fixture_lead("L-1002") }

    it "fails the layer on the consensus, not on any one vendor" do
      expect(outcome.verdict).to eq("consensus_invalid")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to eq("2/3 providers say the number is invalid")
      expect(outcome.signals).to eq([ "consensus_invalid" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  # L-1007: one dissenter out of three. Doubt about the data rather than a fact
  # about the number.
  describe "providers that disagree about whether the number is real (L-1007)" do
    let(:outcome) { process_fixture_lead("L-1007") }

    # The vendor names are reported alphabetically on purpose: jsonb key order is
    # not the order the payload was written in.
    it "warns and names which vendor to doubt" do
      expect(outcome.verdict).to eq("providers_disagree")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq(
        "providers disagree — numverify says invalid, telesign and twilio_lookup say valid"
      )
      expect(outcome.signals).to eq([ "providers_disagree" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  # L-1009: all three agree the number is real and all three agree it is a
  # throwaway app line. Agreement on VoIP is not disagreement, and the two must
  # never collapse into one signal.
  describe "three providers agreeing the number is VoIP (L-1009)" do
    let(:outcome) { process_fixture_lead("L-1009") }

    it "warns about what the number is, not about the data" do
      expect(outcome.verdict).to eq("consensus_voip")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq("3/3 valid — all VoIP (TextNow)")
      expect(outcome.signals).to eq([ "consensus_voip" ])
      expect_signals_to_be_weighted(outcome)
    end

    it "is a different signal from providers disagreeing" do
      disagreeing = process_fixture_lead("L-1007", public_id: "L-9007")

      expect(outcome.signals).not_to eq(disagreeing.signals)
    end
  end

  # L-1011: everyone agrees it is real and nobody agrees what kind of line it is.
  describe "a number whose line type the providers cannot agree on (L-1011)" do
    let(:outcome) { process_fixture_lead("L-1011") }

    it "warns lightly" do
      expect(outcome.verdict).to eq("line_type_split")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq("3/3 valid, line types differ (landline, mobile)")
      expect(outcome.signals).to eq([ "line_type_split" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  describe "three providers agreeing on a real mobile (L-1001)" do
    let(:outcome) { process_fixture_lead("L-1001") }

    it "passes with the wording the panel already shows" do
      expect(outcome.verdict).to eq("valid_consensus")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to eq("3/3 providers valid mobile")
      expect(outcome.signals).to be_empty
    end
  end

  it "treats every provider saying invalid as a consensus, not a disagreement" do
    outcome = process_payload({
      "providers" => {
        "twilio_lookup" => { "valid" => false, "line_type" => "unknown" },
        "numverify" => { "valid" => false, "line_type" => "unknown" },
        "telesign" => { "valid" => false, "line_type" => "unknown" }
      }
    })

    expect(outcome.verdict).to eq("consensus_invalid")
    expect(outcome.detail).to eq("3/3 providers say the number is invalid")
  end

  # No answers is not a consensus. Falling through to the pass branch reported
  # "0/0 providers valid" as a cleared check — a pass on the certificate earned by
  # an empty payload rather than by anyone actually looking the number up.
  it "reports a vendor that returned no providers as a check that did not run" do
    outcome = process_payload({ "providers" => {} })

    expect(outcome.status).to eq("not_applicable")
    expect(outcome.panel_verdict).to eq("skip")
    expect(outcome.detail).to eq("no provider responses")
    expect(outcome.signals).to be_empty
  end

  it "reports a payload missing the providers key the same way" do
    outcome = process_payload({})

    expect(outcome.status).to eq("not_applicable")
  end
end
