# frozen_string_literal: true

module Layers
  # Litigator screening. A serial TCPA plaintiff is the most expensive lead a
  # buyer can dial, so a confirmed match is a hard stop the engine recognises by
  # the verdict string.
  #
  # `suspected` deliberately is not: a loose pattern match is a reason for a human
  # to look, not a reason to destroy a possibly-good lead. A buyer who disagrees
  # promotes it with `treat_as_hard_stop` and no deploy.
  class BlacklistAllianceProcessor < BaseProcessor
    def call
      case payload["status"]
      when "litigator" then litigator
      when "suspected" then suspected
      else                  completed(verdict: "clean", panel_verdict: "pass", detail: "no litigator match")
      end
    end

    private

    def litigator
      completed(
        verdict: "litigator",
        panel_verdict: "fail",
        detail: "confirmed litigator, match score #{payload['match_score']}#{sources_detail}"
      )
    end

    def suspected
      completed(
        verdict: "suspected",
        panel_verdict: "warn",
        detail: "pattern watchlist, not confirmed — match score #{payload['match_score']}#{sources_detail}",
        signals: [ "suspected" ]
      )
    end

    def sources_detail
      sources = Array(payload["sources"])
      return "" if sources.empty?

      " (#{sources.join(', ')})"
    end
  end
end
