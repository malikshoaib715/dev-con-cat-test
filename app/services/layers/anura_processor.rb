# frozen_string_literal: true

module Layers
  # Bot, malware and fraud-farm detection. One voice in the consensus, not the
  # final answer — except for `bad`, which is a hard stop the engine recognises by
  # this exact verdict string.
  #
  # `suspect` is deliberately split by what the vendor suspected: an anonymizer is
  # a lead worth a second look, a fraud farm is a lead worth refusing.
  class AnuraProcessor < BaseProcessor
    SUSPECT_TYPES = {
      "human_fraud_farm" => { verdict: "suspect_fraud_farm", panel_verdict: "fail", label: "fraud-farm cluster" },
      "anonymizer" => { verdict: "suspect_anonymizer", panel_verdict: "warn", label: "anonymizer" }
    }.freeze

    UNCLASSIFIED_SUSPECT = { verdict: "suspect", panel_verdict: "warn", label: "unclassified" }.freeze

    def call
      case payload["result"]
      when "bad"     then bad
      when "suspect" then suspect
      else                completed(verdict: "good", panel_verdict: "pass", detail: "result: good")
      end
    end

    private

    # No signals: the engine forces the score to zero on a hard stop, so weighting
    # this would be arithmetic nobody reads.
    def bad
      completed(verdict: "bad", panel_verdict: "fail", detail: detail_for("bad (bot/malware)"))
    end

    def suspect
      classification = SUSPECT_TYPES.fetch(payload["invalid_traffic_type"], UNCLASSIFIED_SUSPECT)

      completed(
        verdict: classification.fetch(:verdict),
        panel_verdict: classification.fetch(:panel_verdict),
        detail: detail_for("suspect (#{classification.fetch(:label)})"),
        signals: [ classification.fetch(:verdict) ]
      )
    end

    # The rule ids are the vendor's reasoning, and a buyer asking "why was this
    # rejected?" deserves them rather than a bare label.
    def detail_for(summary)
      rules = Array(payload["rule_ids"])
      return "result: #{summary}" if rules.empty?

      "result: #{summary} — #{rules.join(', ')}"
    end
  end
end
