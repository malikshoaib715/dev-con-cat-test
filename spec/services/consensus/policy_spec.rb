require "rails_helper"

RSpec.describe Consensus::Policy do
  before { load_layer_definitions }

  let(:account) { create(:account) }

  def policy_for(account)
    as_tenant(account) { described_class.for(account: account) }
  end

  describe "weights" do
    it "reads the seeded default for a layer the buyer has not retuned" do
      expect(policy_for(account).weight_for("anura", "suspect_fraud_farm")).to eq(-50)
    end

    it "prefers the buyer's override to the default" do
      as_tenant(account) do
        create(:layer_policy, account: account, layer_key: "anura",
                              weight_overrides: { "suspect_fraud_farm" => -80 })
      end

      expect(policy_for(account).weight_for("anura", "suspect_fraud_farm")).to eq(-80)
    end

    it "keeps the defaults an override does not mention" do
      as_tenant(account) do
        create(:layer_policy, account: account, layer_key: "anura", weight_overrides: { "suspect" => -5 })
      end

      policy = policy_for(account)
      expect(policy.weight_for("anura", "suspect")).to eq(-5)
      expect(policy.weight_for("anura", "suspect_anonymizer")).to eq(-35)
    end

    # Both sides of the merge come out of jsonb, where a buyer's override can hold
    # a string, a float or a null. A weight that reached the scorer as one of those
    # would take a verification down with a TypeError.
    it "coerces an override the buyer typed as a string" do
      as_tenant(account) do
        create(:layer_policy, account: account, layer_key: "anura", weight_overrides: { "suspect" => "-40" })
      end

      expect(policy_for(account).weight_for("anura", "suspect")).to eq(-40)
    end

    it "treats a null override as no weight at all" do
      as_tenant(account) do
        create(:layer_policy, account: account, layer_key: "anura", weight_overrides: { "suspect" => nil })
      end

      expect(policy_for(account).weight_for("anura", "suspect")).to eq(0)
    end

    it "treats an override that is not a number at all as no weight" do
      as_tenant(account) do
        create(:layer_policy, account: account, layer_key: "anura",
                              weight_overrides: { "suspect" => { "nested" => true } })
      end

      expect(policy_for(account).weight_for("anura", "suspect")).to eq(0)
    end

    it "scores an unweighted signal at zero rather than raising" do
      expect(policy_for(account).weight_for("anura", "a_signal_nobody_defined")).to eq(0)
    end

    it "scores a deliberately unweighted signal at zero" do
      expect(policy_for(account).weight_for("dnc", "window_closed")).to eq(0)
    end
  end

  describe "hard stops" do
    it "recognises the vendor verdict strings the processors record" do
      policy = policy_for(account)

      expect(policy).to be_hard_stop("anura", "bad")
      expect(policy).to be_hard_stop("trustedform", "mismatch")
      expect(policy).to be_hard_stop("trustedform", "expired")
      expect(policy).to be_hard_stop("trustedform", "not_found")
      expect(policy).to be_hard_stop("blacklist_alliance", "litigator")
      expect(policy).to be_hard_stop("dnc", "dnc_listed")
      expect(policy).to be_hard_stop("dnc", "internal_dnc")
      expect(policy).to be_hard_stop("duplicate_detection", "exact_duplicate")
    end

    it "leaves a weighted signal short of a stop by default" do
      policy = policy_for(account)

      expect(policy).not_to be_hard_stop("blacklist_alliance", "suspected")
      expect(policy).not_to be_hard_stop("anura", "suspect_anonymizer")
    end

    it "treats a blank verdict as no stop" do
      expect(policy_for(account)).not_to be_hard_stop("anura", nil)
    end

    context "when the buyer promotes a layer" do
      before do
        as_tenant(account) do
          create(:layer_policy, account: account, layer_key: "blacklist_alliance", treat_as_hard_stop: true)
        end
      end

      it "refuses every signal that layer penalises" do
        expect(policy_for(account)).to be_hard_stop("blacklist_alliance", "suspected")
      end

      it "keeps that layer's own default stop" do
        expect(policy_for(account)).to be_hard_stop("blacklist_alliance", "litigator")
      end

      it "does not touch any other layer" do
        expect(policy_for(account)).not_to be_hard_stop("anura", "suspect_anonymizer")
      end

      # Promotion refuses what a layer penalises. A signal weighted at zero costs
      # the lead nothing by design, so promoting the layer must not turn it into a
      # rejection.
      it "leaves a deliberately unweighted signal alone" do
        as_tenant(account) do
          create(:layer_policy, account: account, layer_key: "dnc", treat_as_hard_stop: true)
        end

        expect(policy_for(account)).not_to be_hard_stop("dnc", "window_closed")
        expect(policy_for(account)).to be_hard_stop("dnc", "dnc_listed")
      end
    end
  end

  describe "criticality" do
    it "marks the compliance layers as required" do
      policy = policy_for(account)

      expect(policy).to be_required("trustedform")
      expect(policy).to be_required("dnc")
      expect(policy).to be_required("blacklist_alliance")
      expect(policy).to be_required("duplicate_detection")
    end

    it "leaves the vendor-signal layers optional" do
      policy = policy_for(account)

      expect(policy).not_to be_required("anura")
      expect(policy).not_to be_required("vpn_proxy")
      expect(policy).not_to be_required("voice")
    end
  end

  describe "thresholds" do
    it "defaults to the documented bands" do
      policy = policy_for(account)

      expect(policy.accept_threshold).to eq(70)
      expect(policy.review_threshold).to eq(40)
    end

    it "honours a buyer's overrides from settings" do
      account.update!(settings: { "accept_threshold" => 85, "review_threshold" => 50 })
      policy = policy_for(account)

      expect(policy.accept_threshold).to eq(85)
      expect(policy.review_threshold).to eq(50)
    end

    it "reads an override stored as a numeric string" do
      account.update!(settings: { "accept_threshold" => "85" })

      expect(policy_for(account).accept_threshold).to eq(85)
    end

    # "abc".to_i is 0, and 0 is truthy — so before Integer() this yielded an
    # accept threshold of zero and every lead that escaped a hard stop accepted.
    it "falls back to the default when an override does not parse as a number" do
      account.update!(settings: { "accept_threshold" => "definitely high" })

      expect(policy_for(account).accept_threshold).to eq(70)
    end

    it "truncates a float override to whole points" do
      account.update!(settings: { "accept_threshold" => 85.9 })

      expect(policy_for(account).accept_threshold).to eq(85)
    end
  end

  describe "#snapshot" do
    it "records the thresholds, weights, stops and criticality actually in force" do
      as_tenant(account) do
        create(:layer_policy, account: account, layer_key: "blacklist_alliance",
                              treat_as_hard_stop: true, weight_overrides: { "suspected" => -40 })
      end

      snapshot = policy_for(account).snapshot

      expect(snapshot["engine_version"]).to eq(described_class::ENGINE_VERSION)
      expect(snapshot["thresholds"]).to eq({ "accept" => 70, "review" => 40 })
      expect(snapshot.dig("layers", "blacklist_alliance")).to eq(
        "weights" => { "suspected" => -40 },
        "hard_stops" => %w[litigator suspected],
        "criticality" => "required"
      )
    end

    it "covers every layer in the registry with string keys throughout" do
      snapshot = policy_for(account).snapshot

      expect(snapshot["layers"].keys).to match_array(Layers::Registry.keys)
      expect(snapshot.to_json).to eq(JSON.parse(snapshot.to_json).to_json)
    end
  end
end
