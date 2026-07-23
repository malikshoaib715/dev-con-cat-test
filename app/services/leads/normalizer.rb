# frozen_string_literal: true

module Leads
  # The one definition of "the same person". Every identity comparison in the
  # system — CRM duplicate detection, the provider fixture lookup, the CRM search
  # box — goes through these two functions, so two records match here or they do
  # not match anywhere.
  #
  # Deliberately not a service: there is no result to succeed or fail, no
  # collaborator, and nothing to audit. Two pure functions.
  module Normalizer
    NORTH_AMERICAN_DIGITS = 10
    COUNTRY_CODE = "1"

    class << self
      # Case is folded and surrounding whitespace dropped, and nothing else.
      # Homoglyphs are preserved byte for byte: L-1008's address carries a
      # Cyrillic "о" in place of the Latin one, and transliterating it would
      # quietly turn a lead whose domain does not resolve into one that does.
      # Spotting that is the email provider's job; ours is exact matching.
      def email(raw)
        raw.to_s.strip.downcase.presence
      end

      # Reduced to digits and then given a country code, so the many shapes a
      # visitor types — "(310) 555-0142", "310-555-0142", "+1 310 555 0142" —
      # all land on the "+13105550142" the fixtures and the CRM use.
      def phone(raw)
        digits = raw.to_s.gsub(/\D/, "")
        return nil if digits.empty?

        "+#{with_country_code(digits)}"
      end

      private

      def with_country_code(digits)
        return "#{COUNTRY_CODE}#{digits}" if digits.length == NORTH_AMERICAN_DIGITS

        digits
      end
    end
  end
end
