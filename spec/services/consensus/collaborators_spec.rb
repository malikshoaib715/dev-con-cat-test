require "rails_helper"

# The engine's three collaborators, each on its own. Consensus::Engine's spec
# proves how they combine; these cover the edges only visible from inside.
RSpec.describe "the consensus collaborators" do
  def rules(weights: {})
    definitions = Layers::Registry.keys.map do |key|
      build(:layer_definition, key: key, default_weights: weights.fetch(key, {}))
    end

    Consensus::Policy.new(account: build(:account), definitions: definitions, overrides: [])
  end

  def row(layer_key, status: "completed", verdict: nil, detail: "vendor said so", raw_response: {})
    ScoredRow.new(layer_key: layer_key, status: status, verdict: verdict, detail: detail,
                  raw_response: raw_response)
  end

  describe Consensus::HardStopEvaluator do
    it "reports the layer, its verdict and what it found" do
      stop = described_class.call(rows: [ row("anura", verdict: "bad", detail: "bot") ], policy: rules)

      expect(stop.layer_key).to eq("anura")
      expect(stop.verdict).to eq("bad")
      expect(stop.detail).to eq("bot")
    end

    it "finds nothing in a clean run" do
      expect(described_class.call(rows: [ row("anura", verdict: "good") ], policy: rules)).to be_nil
    end

    it "ignores a layer that never ran" do
      rows = [ row("duplicate_detection", status: "not_enabled", verdict: "exact_duplicate") ]

      expect(described_class.call(rows: rows, policy: rules)).to be_nil
    end
  end

  describe Consensus::SignalScorer do
    it "scores from the signals the processor recorded" do
      policy = rules(weights: { "anura" => { "suspect" => -15 } })
      rows = [ row("anura", verdict: "suspect", raw_response: { "signals" => [ "suspect" ] }) ]

      expect(described_class.call(rows: rows, policy: policy).score).to eq(85)
    end

    # A row written before signals were recorded alongside the vendor's answer:
    # its own verdict is the best description of what it found, so the weight is
    # looked up by that rather than the row being silently ignored.
    it "falls back to the row's verdict when no signals were recorded" do
      policy = rules(weights: { "anura" => { "suspect" => -15 } })
      rows = [ row("anura", verdict: "suspect", raw_response: {}) ]

      expect(described_class.call(rows: rows, policy: policy).score).to eq(85)
    end

    it "keeps a layer that cost nothing out of the reasons but in the deltas" do
      scoring = described_class.call(rows: [ row("dnc", verdict: "callable") ], policy: rules)

      expect(scoring.penalties).to be_empty
      expect(scoring.per_layer_deltas).to eq("dnc" => 0)
    end
  end

  describe Consensus::ReasonBuilder do
    def penalty(layer_key, delta, detail: "vendor said so", signals: [])
      Consensus::SignalScorer::Contribution.new(layer_key: layer_key, signals: signals,
                                                detail: detail, delta: delta)
    end

    it "leads with the hard stop and still reports what else was unavailable" do
      stop = Consensus::HardStopEvaluator::Stop.new(layer_key: "dnc", verdict: "dnc_listed",
                                                    detail: "listed")
      unavailable = [ Consensus::Engine::Unavailable.new(layer_key: "enrichment", required: false) ]

      reasons = described_class.call(stop: stop, penalties: [ penalty("anura", -15) ],
                                     unavailable: unavailable, answered: true)

      expect(reasons.first).to eq("hard stop — DNC / Callback: listed")
      expect(reasons.last).to include("enrichment")
      expect(reasons.none? { |reason| reason.include?("Anura") }).to be(true)
    end

    it "signs a positive adjustment so a buyer's reweighting reads correctly" do
      reasons = described_class.call(stop: nil, penalties: [ penalty("anura", 5) ], unavailable: [],
                                     answered: true)

      expect(reasons).to eq([ "Anura: vendor said so (+5)" ])
    end

    it "never reads as a clean pass when no layer answered at all" do
      reasons = described_class.call(stop: nil, penalties: [], unavailable: [], answered: false)

      expect(reasons).to eq([ described_class::NOTHING_ANSWERED ])
    end

    it "does not claim every layer passed when one of them could not answer" do
      unavailable = [ Consensus::Engine::Unavailable.new(layer_key: "dnc", required: true) ]
      reasons = described_class.call(stop: nil, penalties: [], unavailable: unavailable, answered: true)

      expect(reasons).to eq([ "required layer unavailable: dnc — verdict capped at review" ])
    end
  end
end
