# frozen_string_literal: true

module Layers
  # May the buyer legally dial this number right now?
  #
  # Both listed statuses are hard stops, matched by the engine on these verdict
  # strings: if it cannot be called, there is nothing to buy. A closed callback
  # window is a timing problem rather than a compliance one, so it is surfaced for
  # a human and left unweighted.
  class DncProcessor < BaseProcessor
    LISTED_DETAILS = {
      "dnc_listed" => "listed on the do-not-call registry",
      "internal_dnc" => "on this buyer's internal do-not-call list"
    }.freeze

    REGISTRIES = { "national_dnc" => "National", "state_dnc" => "State" }.freeze

    def call
      return no_dialable_phone unless dialable_phone?

      status = payload["dnc_status"]
      return listed(status) if LISTED_DETAILS.key?(status)
      return window_closed if payload["callback_window_open"] == false

      completed(verdict: "callable", panel_verdict: "pass", detail: "callable, window open")
    end

    private

    def listed(status)
      completed(verdict: status, panel_verdict: "fail", detail: "#{LISTED_DETAILS.fetch(status)}#{registries_detail}")
    end

    def window_closed
      completed(
        verdict: "window_closed",
        panel_verdict: "warn",
        detail: "callable, but the callback window is closed#{last_contact_detail}",
        signals: [ "window_closed" ]
      )
    end

    def registries_detail
      named = REGISTRIES.filter_map { |field, label| label if payload[field] }
      return "" if named.empty?

      " (#{named.to_sentence})"
    end

    def last_contact_detail
      last_contact = payload["last_contact_at"]
      return "" if last_contact.blank?

      " — last contacted #{last_contact}"
    end
  end
end
