require "rails_helper"

# Deliberately database-free: the rules are the thing under test, and they hold
# whether or not anything has been persisted. The twelve fixture leads are proved
# end to end by spec/seeds/harness_spec.rb.
RSpec.describe Consensus::Engine do
  def row(layer_key, status: "completed", verdict: nil, detail: "vendor said so", signals: [])
    ScoredRow.new(layer_key: layer_key, status: status, verdict: verdict, detail: detail,
                  raw_response: { "signals" => signals })
  end

  def policy(weights: {}, required: [], promoted: [], settings: {})
    definitions = Layers::Registry.keys.map do |key|
      build(:layer_definition, key: key,
                               criticality: required.include?(key) ? "required" : "optional",
                               default_weights: weights.fetch(key, {}))
    end
    overrides = promoted.map do |key|
      PolicyOverride.new(layer_key: key, treat_as_hard_stop: true, weight_overrides: {})
    end

    Consensus::Policy.new(account: build(:account, settings: settings), definitions: definitions,
                          overrides: overrides)
  end

  def decide(rows, policy)
    described_class.call(run: instance_double(VerificationRun, layer_results: rows), policy: policy)
  end

  describe "hard stops" do
    [
      [ "anura", "bad" ],
      [ "trustedform", "mismatch" ],
      [ "trustedform", "expired" ],
      [ "trustedform", "not_found" ],
      [ "blacklist_alliance", "litigator" ],
      [ "dnc", "dnc_listed" ],
      [ "dnc", "internal_dnc" ],
      [ "duplicate_detection", "exact_duplicate" ]
    ].each do |layer_key, verdict|
      it "rejects outright when #{layer_key} returns #{verdict}" do
        decision = decide([ row(layer_key, verdict: verdict) ], policy)

        expect(decision.verdict).to eq("reject")
        expect(decision.score).to eq(0)
        expect(decision.hard_stop_layer).to eq(layer_key)
      end
    end

    it "names the stop and what the layer found" do
      decision = decide([ row("dnc", verdict: "dnc_listed", detail: "listed on the do-not-call registry") ], policy)

      expect(decision.reasons.first).to eq("hard stop — DNC / Callback: listed on the do-not-call registry")
    end

    it "names the earlier layer in registry order when a lead trips two stops" do
      rows = [ row("dnc", verdict: "dnc_listed"), row("trustedform", verdict: "mismatch") ]

      expect(decide(rows, policy).hard_stop_layer).to eq("trustedform")
      expect(decide(rows.reverse, policy).hard_stop_layer).to eq("trustedform")
    end

    it "flags an exact duplicate so the CRM can render it as such" do
      decision = decide([ row("duplicate_detection", verdict: "exact_duplicate") ], policy)

      expect(decision.flags).to include("duplicate")
    end

    it "does not stop on a signal the buyer has not promoted" do
      rules = policy(weights: { "blacklist_alliance" => { "suspected" => -25 } })
      decision = decide([ row("blacklist_alliance", verdict: "suspected", signals: [ "suspected" ]) ], rules)

      expect(decision.verdict).to eq("accept")
      expect(decision.score).to eq(75)
      expect(decision.hard_stop_layer).to be_nil
    end

    it "stops on that same signal once the buyer promotes the layer" do
      rules = policy(weights: { "blacklist_alliance" => { "suspected" => -25 } },
                     promoted: [ "blacklist_alliance" ])
      decision = decide([ row("blacklist_alliance", verdict: "suspected", signals: [ "suspected" ]) ], rules)

      expect(decision.verdict).to eq("reject")
      expect(decision.score).to eq(0)
      expect(decision.hard_stop_layer).to eq("blacklist_alliance")
    end

    it "ignores a stop verdict on a layer that errored rather than answered" do
      decision = decide([ row("dnc", status: "errored", verdict: "dnc_listed") ], policy)

      expect(decision.hard_stop_layer).to be_nil
    end
  end

  describe "bands" do
    def scored(delta, **options)
      rules = policy(weights: { "anura" => { "tuned" => delta } }, **options)
      decide([ row("anura", signals: [ "tuned" ]) ], rules)
    end

    it "accepts at the threshold" do
      expect(scored(-30).score).to eq(70)
      expect(scored(-30).verdict).to eq("accept")
    end

    it "reviews one point below it" do
      expect(scored(-31).score).to eq(69)
      expect(scored(-31).verdict).to eq("review")
    end

    it "reviews at the review threshold" do
      expect(scored(-60).score).to eq(40)
      expect(scored(-60).verdict).to eq("review")
    end

    it "rejects one point below it" do
      expect(scored(-61).score).to eq(39)
      expect(scored(-61).verdict).to eq("reject")
    end

    it "clamps at zero rather than going negative" do
      expect(scored(-400).score).to eq(0)
      expect(scored(-400).verdict).to eq("reject")
    end

    it "moves the bands when the buyer overrides the thresholds" do
      decision = scored(-20, settings: { "accept_threshold" => 90, "review_threshold" => 50 })

      expect(decision.score).to eq(80)
      expect(decision.verdict).to eq("review")
    end
  end

  describe "scoring" do
    it "sums every signal a layer reported" do
      rules = policy(weights: { "email_validation" => { "both_undeliverable" => -35, "disposable" => -25 } })
      decision = decide([ row("email_validation", signals: %w[both_undeliverable disposable]) ], rules)

      expect(decision.score).to eq(40)
      expect(decision.per_layer_deltas).to eq("email_validation" => -60)
    end

    it "costs nothing for a signal that is weighted at zero" do
      rules = policy(weights: { "dnc" => { "window_closed" => 0 } })
      decision = decide([ row("dnc", verdict: "window_closed", signals: [ "window_closed" ]) ], rules)

      expect(decision.score).to eq(100)
      expect(decision.verdict).to eq("accept")
      expect(decision.reasons).to eq([ Consensus::ReasonBuilder::CLEAN ])
    end

    it "costs nothing for a signal nobody weighted" do
      decision = decide([ row("anura", signals: [ "a_signal_nobody_defined" ]) ], policy)

      expect(decision.score).to eq(100)
    end

    it "never penalises a lead for a layer the buyer did not buy" do
      rules = policy(weights: { "voice" => { "reused_actor" => -50 } })
      decision = decide([ row("voice", status: "not_enabled", verdict: nil) ], rules)

      expect(decision.score).to eq(100)
      expect(decision.per_layer_deltas).to be_empty
      expect(decision.reasons).to eq([ Consensus::ReasonBuilder::CLEAN ])
    end

    it "never penalises a lead for a layer that had nothing to judge" do
      rules = policy(weights: { "voice" => { "reused_actor" => -50 } })
      decision = decide([ row("voice", status: "not_applicable", detail: "no voice sample") ], rules)

      expect(decision.score).to eq(100)
      expect(decision.reasons).to eq([ Consensus::ReasonBuilder::CLEAN ])
    end

    it "reports each layer's contribution so the lead page can show it" do
      rules = policy(weights: { "anura" => { "suspect" => -15 },
                                "phone_validation" => { "providers_disagree" => -20 } })
      rows = [ row("anura", signals: [ "suspect" ]),
               row("phone_validation", signals: [ "providers_disagree" ]),
               row("dnc", verdict: "callable") ]

      expect(decide(rows, rules).per_layer_deltas).to eq(
        "anura" => -15, "phone_validation" => -20, "dnc" => 0
      )
    end

    it "flags a soft duplicate for a human without rejecting the lead" do
      rules = policy(weights: { "duplicate_detection" => { "soft_duplicate" => -10 } })
      decision = decide([ row("duplicate_detection", verdict: "soft_duplicate", signals: [ "soft_duplicate" ]) ],
                        rules)

      expect(decision.verdict).to eq("accept")
      expect(decision.score).to eq(90)
      expect(decision.flags).to eq([ "soft_duplicate" ])
    end
  end

  describe "reasons" do
    it "orders them by how much each layer moved the verdict" do
      rules = policy(weights: { "vpn_proxy" => { "risk_medium" => -5 },
                                "anura" => { "suspect_fraud_farm" => -50 },
                                "enrichment" => { "sources_disagree" => -12 } })
      rows = [ row("vpn_proxy", signals: [ "risk_medium" ], detail: "medium risk"),
               row("anura", signals: [ "suspect_fraud_farm" ], detail: "fraud-farm cluster"),
               row("enrichment", signals: [ "sources_disagree" ], detail: "sources disagree") ]

      expect(decide(rows, rules).reasons).to eq([
        "Anura: fraud-farm cluster (-50)",
        "Enrichment: sources disagree (-12)",
        "VPN / Proxy: medium risk (-5)"
      ])
    end

    it "says so plainly when nothing was found" do
      rows = [ row("anura", verdict: "good"), row("dnc", verdict: "callable") ]

      expect(decide(rows, policy).reasons).to eq([ "all enabled layers passed" ])
    end
  end

  describe "when a layer could not answer" do
    let(:required_rules) { policy(required: %w[dnc trustedform]) }

    it "caps an otherwise clean lead at review when a required layer errored" do
      decision = decide([ row("anura", verdict: "good"), row("dnc", status: "errored") ], required_rules)

      expect(decision.verdict).to eq("review")
      expect(decision.score).to eq(100)
      expect(decision.flags).to include("required_layer_unavailable")
      expect(decision.reasons).to include("required layer unavailable: dnc — verdict capped at review")
    end

    it "leaves a rejection a rejection" do
      rows = [ row("trustedform", verdict: "mismatch"), row("dnc", status: "errored") ]

      expect(decide(rows, required_rules).verdict).to eq("reject")
    end

    it "lets an optional layer fail open, scoring nothing but saying so" do
      decision = decide([ row("anura", verdict: "good"), row("enrichment", status: "errored") ], required_rules)

      expect(decision.verdict).to eq("accept")
      expect(decision.score).to eq(100)
      expect(decision.flags).not_to include("required_layer_unavailable")
      expect(decision.reasons).to include(
        "optional layer unavailable: enrichment — recorded, not counted as a pass"
      )
    end

    it "never counts an unavailable layer as a pass" do
      decision = decide([ row("dnc", status: "errored") ], required_rules)

      expect(decision.reasons).not_to include(Consensus::ReasonBuilder::CLEAN)
    end
  end

  it "carries the policy it used so the verdict stays explainable" do
    decision = decide([ row("anura", verdict: "good") ], policy)

    expect(decision.policy_snapshot["thresholds"]).to eq({ "accept" => 70, "review" => 40 })
    expect(decision.policy_snapshot["layers"].keys).to match_array(Layers::Registry.keys)
  end
end
