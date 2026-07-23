require "rails_helper"

RSpec.describe Layers::VoiceProcessor do
  before { load_layer_fixtures(described_class.layer_key) }

  it "belongs to the voice layer" do
    expect(described_class.layer_key).to eq("voice")
  end

  # Most leads arrive through a web form. A check that did not apply is not a
  # check that passed, and the certificate has to keep the difference.
  describe "a lead with no voice sample (L-1001)" do
    let(:outcome) { process_fixture_lead("L-1001") }

    it "is not applicable rather than a pass" do
      expect(outcome.status).to eq("not_applicable")
      expect(outcome.verdict).to be_nil
      expect(outcome.panel_verdict).to eq("skip")
      expect(outcome.detail).to eq("no voice sample")
      expect(outcome.signals).to be_empty
    end
  end

  # L-1009: one voiceprint submitted under four names in thirty days. Voice-actor
  # fraud, and the heaviest single signal in the system.
  describe "a voiceprint reused across other leads (L-1009)" do
    let(:outcome) { process_fixture_lead("L-1009") }

    it "fails the layer and produces the evidence" do
      expect(outcome.status).to eq("completed")
      expect(outcome.verdict).to eq("reused_actor")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to eq(
        "voiceprint reused across other leads — voiceprint vp_41fe — 3 prior leads: L-0912, L-0977, L-1044"
      )
      expect(outcome.signals).to eq([ "reused_actor" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  describe "a synthesised voice" do
    let(:outcome) do
      process_payload({ "has_sample" => true, "verdict" => "synthetic", "voiceprint_id" => "vp_0001" })
    end

    it "fails the layer" do
      expect(outcome.verdict).to eq("synthetic")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to eq("synthetic (AI-generated) voice detected — voiceprint vp_0001")
      expect(outcome.signals).to eq([ "synthetic" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  describe "a unique human voice (L-1006)" do
    let(:outcome) { process_fixture_lead("L-1006") }

    it "passes with nothing to score" do
      expect(outcome.status).to eq("completed")
      expect(outcome.verdict).to eq("human_unique")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to eq("unique human voiceprint")
      expect(outcome.signals).to be_empty
    end
  end

  # A brand-new lead has no sample, so the clean default has to skip rather than
  # invent a pass it cannot justify.
  it "skips a lead the gateway has never heard of" do
    account = create(:account)
    stranger = as_tenant(account) { create(:lead, account: account, email_normalized: "nobody@example.com") }

    outcome = as_tenant(account) { described_class.call(lead: stranger) }

    expect(outcome.status).to eq("not_applicable")
    expect(outcome.panel_verdict).to eq("skip")
  end

  it "treats an unrecognised voice verdict as a human rather than inventing a failure" do
    outcome = process_payload({ "has_sample" => true, "verdict" => "something_new" })

    expect(outcome.verdict).to eq("human_unique")
  end
end
