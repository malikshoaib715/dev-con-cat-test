require "rails_helper"

RSpec.describe Layers::DncProcessor do
  before { load_layer_fixtures(described_class.layer_key) }

  it "belongs to the dnc layer" do
    expect(described_class.layer_key).to eq("dnc")
  end

  # L-1005 is on both registries. This is also the hard stop that has to fire for
  # acct_autoinsure, which never bought litigator screening: the litigator layer
  # cannot be what rejects this lead.
  describe "a number on the do-not-call registry (L-1005)" do
    let(:outcome) { process_fixture_lead("L-1005") }

    it "fails the layer and names the registries" do
      expect(outcome.verdict).to eq("dnc_listed")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to eq("listed on the do-not-call registry (National and State)")
      expect(outcome.signals).to be_empty
    end
  end

  describe "a number listed nationally only (L-1006)" do
    let(:outcome) { process_fixture_lead("L-1006") }

    it "names just the registry that listed it" do
      expect(outcome.verdict).to eq("dnc_listed")
      expect(outcome.detail).to eq("listed on the do-not-call registry (National)")
    end
  end

  describe "a number on the buyer's own suppression list" do
    let(:outcome) do
      process_payload({ "dnc_status" => "internal_dnc", "national_dnc" => false, "state_dnc" => false })
    end

    it "is just as fatal as the public registry" do
      expect(outcome.verdict).to eq("internal_dnc")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to eq("on this buyer's internal do-not-call list")
    end
  end

  describe "a callable number outside its callback window" do
    let(:outcome) do
      process_payload({
        "dnc_status" => "callable", "callback_window_open" => false,
        "last_contact_at" => "2026-06-30T18:22:00Z"
      })
    end

    # A timing problem, not a compliance one: whoever works the lead needs to know,
    # but the lead is not worth less.
    it "warns, says when they were last contacted, and costs nothing" do
      expect(outcome.verdict).to eq("window_closed")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq(
        "callable, but the callback window is closed — last contacted 2026-06-30T18:22:00Z"
      )
      expect(outcome.signals).to eq([ "window_closed" ])
    end

    it "is weighted at zero explicitly, so the signal is not a silent no-op" do
      expect(LayerDefinition.find_by!(key: "dnc").default_weights).to include("window_closed" => 0)
      expect_signals_to_be_weighted(outcome)
    end
  end

  describe "a number the buyer may dial right now (L-1001)" do
    let(:outcome) { process_fixture_lead("L-1001") }

    it "passes with the wording the panel already shows" do
      expect(outcome.verdict).to eq("callable")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to eq("callable, window open")
      expect(outcome.signals).to be_empty
    end
  end

  # L-1004 was contacted at the end of June and is still callable; a prior contact
  # is not by itself a closed window.
  it "does not warn about a prior contact when the window is open (L-1004)" do
    expect(process_fixture_lead("L-1004").verdict).to eq("callable")
  end
end
