# frozen_string_literal: true

module Layers
  # Has this buyer already paid for this person?
  #
  # The only layer with no vendor behind it: the answer lives in the buyer's own
  # CRM, and it is scoped to that buyer. The same person in two buyers' CRMs is two
  # legitimate leads, not a duplicate — which is why this runs inside the run's
  # tenant and never reaches across accounts.
  #
  # A full match on both phone and email is a hard stop. A partial match is
  # deliberately *not*: the same phone with a different address, days apart, is
  # more likely a returning customer than a fraud, and that is a judgement for a
  # human. Auto-rejecting it would throw away good leads.
  class DuplicateDetectionProcessor < BaseProcessor
    RECENCY_WINDOW = 30.days

    def call
      return exact_duplicate if exact_match
      return soft_duplicate if recent_partial_match
      return stale_partial_match if partial_matches.any?

      completed(verdict: "no_match", panel_verdict: "pass", detail: "no CRM match for account")
    end

    private

    def exact_duplicate
      completed(
        verdict: "exact_duplicate",
        panel_verdict: "fail",
        detail: "already in CRM as #{exact_match.external_ref}, captured #{captured_on(exact_match)}"
      )
    end

    def soft_duplicate
      completed(
        verdict: "soft_duplicate",
        panel_verdict: "warn",
        detail: "same #{matched_field(recent_partial_match)} as #{recent_partial_match.external_ref} " \
                "(#{captured_on(recent_partial_match)}), different " \
                "#{differing_field(recent_partial_match)} — possible returning customer",
        signals: [ "soft_duplicate" ]
      )
    end

    # A part-match from months ago is a different enquiry, not a duplicate. Said out
    # loud rather than reported as "no match", because the buyer's own record does
    # exist and whoever works the lead should know.
    def stale_partial_match
      completed(
        verdict: "no_match",
        panel_verdict: "pass",
        detail: "no recent CRM match — #{partial_matches.first.external_ref} shares this lead's " \
                "#{matched_field(partial_matches.first)} but is from #{captured_on(partial_matches.first)}"
      )
    end

    def exact_match
      return @exact_match if defined?(@exact_match)

      @exact_match = candidates.find { |record| same_phone?(record) && same_email?(record) }
    end

    def partial_matches
      @partial_matches ||= candidates - [ exact_match ].compact
    end

    def recent_partial_match
      return @recent_partial_match if defined?(@recent_partial_match)

      @recent_partial_match = partial_matches.find { |record| recent?(record) }
    end

    # Two indexed lookups over one account's records, newest first so the same lead
    # always reports the same match.
    def candidates
      @candidates ||= (matching_phone + matching_email).uniq.sort_by(&:source_created_at).reverse
    end

    def matching_phone
      return [] if lead.phone_normalized.blank?

      CrmRecord.matching_phone(lead.phone_normalized).to_a
    end

    def matching_email
      return [] if lead.email_normalized.blank?

      CrmRecord.matching_email(lead.email_normalized).to_a
    end

    # Absolute difference, not elapsed time: the fixture CRM record for L-1012 is
    # dated a few hours *after* the lead was captured, which is what a CRM export
    # taken later looks like. Only counting the past would miss it.
    def recent?(record)
      (lead.submitted_at - record.source_created_at).abs <= RECENCY_WINDOW
    end

    def same_phone?(record)
      lead.phone_normalized.present? && record.phone_normalized == lead.phone_normalized
    end

    def same_email?(record)
      lead.email_normalized.present? && record.email_normalized == lead.email_normalized
    end

    def matched_field(record)
      same_phone?(record) ? "phone" : "email"
    end

    def differing_field(record)
      same_phone?(record) ? "email" : "phone"
    end

    def captured_on(record)
      record.source_created_at.to_date.to_fs(:long)
    end

    # There is no vendor payload to keep, so the evidence is what was found in the
    # CRM — which is what a buyer disputing a duplicate would ask to see.
    def raw_response
      {
        "crm_matches" => candidates.map do |record|
          {
            "external_ref" => record.external_ref,
            "matched_on" => [ same_phone?(record) ? "phone" : nil, same_email?(record) ? "email" : nil ].compact,
            "source_created_at" => record.source_created_at.iso8601
          }
        end
      }
    end
  end
end
