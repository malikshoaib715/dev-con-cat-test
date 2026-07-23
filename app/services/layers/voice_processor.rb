# frozen_string_literal: true

module Layers
  # For leads captured through a click-to-call or voice step, a short sample is
  # checked for the two ways a voice lies: the same paid actor reused across many
  # "different" people, and a synthesised voice.
  #
  # Most leads arrive through a web form and have no sample. That is
  # `not_applicable` — a check that did not apply — and never a pass. The
  # certificate keeps the difference, because presenting an unrun check as a
  # cleared one is exactly the misrepresentation consent records exist to prevent.
  class VoiceProcessor < BaseProcessor
    FRAUD_VERDICTS = {
      "human_reused_actor" => { verdict: "reused_actor", detail: "voiceprint reused across other leads" },
      "synthetic" => { verdict: "synthetic", detail: "synthetic (AI-generated) voice detected" }
    }.freeze

    def call
      return not_applicable(detail: "no voice sample") unless payload["has_sample"]

      fraud = FRAUD_VERDICTS[payload["verdict"]]
      return voice_fraud(fraud) if fraud

      completed(verdict: "human_unique", panel_verdict: "pass", detail: "unique human voiceprint")
    end

    private

    def voice_fraud(fraud)
      completed(
        verdict: fraud.fetch(:verdict),
        panel_verdict: "fail",
        detail: [ fraud.fetch(:detail), voiceprint_detail, prior_leads_detail ].compact.join(" — "),
        signals: [ fraud.fetch(:verdict) ]
      )
    end

    def voiceprint_detail
      voiceprint_id = payload["voiceprint_id"]
      return nil if voiceprint_id.blank?

      "voiceprint #{voiceprint_id}"
    end

    # Naming how many other leads share the voiceprint is what turns this from an
    # assertion into evidence.
    def prior_leads_detail
      prior = Array(payload["matched_prior_leads"])
      return nil if prior.empty?

      "#{prior.size} prior #{'lead'.pluralize(prior.size)}: #{prior.join(', ')}"
    end
  end
end
