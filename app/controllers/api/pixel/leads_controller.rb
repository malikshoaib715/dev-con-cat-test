# frozen_string_literal: true

module Api
  module Pixel
    # Where a submitted lead enters the system.
    class LeadsController < BaseController
      SUBMITTED_FIELDS = %i[first_name last_name email phone consent].freeze
      # Field churn reaches us only as this submitted summary, shaped exactly like
      # the visit beacon's (§6): the panel renders the live events client-side.
      INTERACTION_KEYS = %i[name action at].freeze

      def create
        result = Leads::IngestionService.call(pixel: current_pixel, attributes: lead_attributes)
        return render_hold(result) if result.failure?

        render_receipt(result.value)
      end

      private

      # `lead_id` is the key the pixel reads to subscribe, so it is named exactly
      # that. A replay is answered with the original lead and a 200: the caller's
      # submission was already accepted, and saying so is not an error.
      #
      # The stream token is withheld from a replay that cannot show it is the page
      # that submitted (see IngestionService#same_identity_as?). A double-click or
      # a browser retry resends the same identity and still gets its token; a
      # guessed session id gets the idempotent answer and no capability with it.
      def render_receipt(receipt)
        body = {
          lead_id: receipt.lead.public_id,
          channel: "VerificationChannel",
          replayed: receipt.replayed
        }
        body[:stream_token] = Realtime::StreamToken.generate(receipt.lead) if receipt.same_submitter

        render json: body, status: receipt.replayed ? :ok : :created
      end

      # 402 rather than a validation error: the lead was fine, the buyer's balance
      # was not. The lead is retained and can be re-run after a top-up.
      def render_hold(result)
        render_error code: "insufficient_credits", message: result.error.to_sentence, status: :payment_required
      end

      # `pixel_id` and `submitted_at` are accepted because the reference snippet
      # sends them, and then ignored: the tenant comes from the key alone, and the
      # capture time comes from our clock. A page-supplied timestamp would be an
      # attacker-supplied one, and it is an input to scoring — the duplicate
      # layer's recency window and TrustedForm's expiry check both compare against
      # it, so a lead claiming to be from 2099 could walk past either. The address
      # and user agent come from the connection for the same reason.
      def lead_attributes
        permitted = params.permit(:session_id, :pixel_id, :submitted_at, :form_dwell_ms, :page_url,
                                  fields: SUBMITTED_FIELDS, interactions: INTERACTION_KEYS)
        raise Errors::ValidationFailed, "session_id is required" if permitted[:session_id].blank?

        permitted.to_h.deep_symbolize_keys.except(:submitted_at).merge(
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
      end
    end
  end
end
