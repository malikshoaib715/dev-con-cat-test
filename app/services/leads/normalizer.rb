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

    # What a number has to be before a vendor could look it up: at least a whole
    # national number (NANP is ten digits) and no longer than E.164 allows with a
    # country code. It is a possibility check, not a validity check — "3105550142"
    # passes here and might still be unassigned, which is precisely the question
    # the phone-consensus layer exists to answer. The line this draws is between
    # a number and a string of digits that could never be one.
    DIALABLE_DIGITS = (NORTH_AMERICAN_DIGITS..15)

    # Deliberately not RFC 5322: that grammar accepts `fghjk@njjj`, and so does
    # every browser's `type="email"`, because a dotless host is legal on a local
    # network. Mail to a lead is not local, so an address a buyer could actually
    # reach needs a dotted domain and a plausible TLD. Everything subtler than
    # this — does the mailbox exist, does the domain accept mail — is the email
    # layer's question, and this only decides whether it is worth asking.
    DELIVERABLE_ADDRESS = /\A[^@\s]+@[^@\s.]+(?:\.[^@\s.]+)*\.[a-z]{2,}\z/i

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

      # Whether a vendor keyed on the phone number could look this up at all.
      # Normalization keeps whatever digits it finds, because a partial number is
      # still worth storing and still worth matching a duplicate on — so ",dc kwc"
      # survives as nothing and "999+1234" survives as "+9991234". Neither is
      # something a DNC registry or a litigator list can answer about, and a layer
      # that reported "callable" about one would be putting a claim on a
      # certificate that no vendor ever made.
      def dialable?(raw)
        DIALABLE_DIGITS.cover?(raw.to_s.gsub(/\D/, "").length)
      end

      # Whether an email provider could attempt delivery. Same bar, same reason.
      def deliverable_shape?(raw)
        email(raw).to_s.match?(DELIVERABLE_ADDRESS)
      end

      private

      def with_country_code(digits)
        return "#{COUNTRY_CODE}#{digits}" if digits.length == NORTH_AMERICAN_DIGITS

        digits
      end
    end
  end
end
