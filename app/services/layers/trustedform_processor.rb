# frozen_string_literal: true

module Layers
  # Can this buyer prove the lead consented? The certificate has to exist, match
  # the person who submitted, cover the page they submitted from, and still be
  # within its window.
  #
  # Every non-verified status is a hard stop and the engine matches these verdict
  # strings directly: unprovable consent is the one thing no score can outweigh.
  class TrustedformProcessor < BaseProcessor
    VERIFIED = "verified"

    UNPROVEN_FALLBACKS = {
      "not_found" => "no certificate was retained for this lead",
      "expired" => "the certificate window has closed",
      "mismatch" => "the certificate does not match this lead"
    }.freeze

    def call
      return verified if payload["status"] == VERIFIED

      unproven
    end

    private

    def verified
      completed(verdict: VERIFIED, panel_verdict: "pass", detail: "cert verified, phone+email match")
    end

    def unproven
      completed(
        verdict: payload["status"],
        panel_verdict: "fail",
        detail: "consent cannot be proven (#{payload['status']}): #{discrepancies.to_sentence}"
      )
    end

    # Reported from the certificate's own fields rather than from the status alone,
    # so the buyer sees which part of the proof failed.
    def discrepancies
      found = [
        ("certificate phone does not match the lead" if payload["matches_phone"] == false),
        ("certificate email does not match the lead" if payload["matches_email"] == false),
        ("page fingerprint differs from the landing page" if page_fingerprint_differs?),
        ("no consent language was present" if payload["consent_language_present"] == false),
        ("the certificate expired #{payload['expires_at']}" if expired?)
      ].compact

      found.presence || [ UNPROVEN_FALLBACKS.fetch(payload["status"], "the certificate could not be verified") ]
    end

    def page_fingerprint_differs?
      certified_page = payload["page_url"]
      return false if certified_page.blank? || lead.page_url.blank?

      certified_page != lead.page_url
    end

    def expired?
      expires_at = parsed_expiry
      return false if expires_at.nil?

      expires_at < lead.submitted_at
    end

    # An expiry the vendor sent in a shape we cannot read is not evidence that the
    # certificate expired, so it is not reported as such. Left unparsed the
    # comparison would raise, and a malformed field on one certificate would take
    # the whole layer down into `errored` rather than describing what it found.
    def parsed_expiry
      raw = payload["expires_at"]
      return nil if raw.blank?

      Time.zone.parse(raw.to_s)
    rescue ArgumentError
      nil
    end
  end
end
