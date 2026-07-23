# frozen_string_literal: true

module Realtime
  # Proves that whoever is asking for a lead's activity is the page that submitted
  # it.
  #
  # The pixel's session id is generated client-side and is therefore guessable, so
  # it can never be what authorises a subscription — anyone could watch another
  # visitor's verification unfold. The signed token issued with the 201 is the
  # capability, it names one lead, and it expires: a page only needs it for as long
  # as its own verification takes.
  #
  # One definition, used by the ingestion response, the channel, and the polling
  # fallback, so the purpose and lifetime cannot drift between them.
  class StreamToken
    PURPOSE = :pixel_stream
    LIFETIME = 15.minutes

    class << self
      def generate(lead)
        verifier.generate(lead.public_id, purpose: PURPOSE, expires_in: LIFETIME)
      end

      # Returns the lead's public id, or nil for a token that is missing, tampered
      # with, expired, or issued for something else entirely.
      def lead_public_id(token)
        return nil if token.blank?

        verifier.verified(token, purpose: PURPOSE)
      end

      private

      def verifier
        Rails.application.message_verifier(PURPOSE)
      end
    end
  end
end
