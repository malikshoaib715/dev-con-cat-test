# frozen_string_literal: true

module Api
  module Pixel
    # Where a submitted lead enters the system.
    class LeadsController < BaseController
      SUBMITTED_FIELDS = %i[first_name last_name email phone consent].freeze

      def create
        result = Leads::IngestionService.call(pixel: current_pixel, attributes: lead_attributes)
        return render_hold(result) if result.failure?

        render_receipt(result.value)
      end

      private

      # `lead_id` is the key the pixel reads to subscribe, so it is named exactly
      # that. A replay is answered with the original lead and a 200: the caller's
      # submission was already accepted, and saying so is not an error.
      def render_receipt(receipt)
        render json: {
          lead_id: receipt.lead.public_id,
          stream_token: Realtime::StreamToken.generate(receipt.lead),
          channel: "VerificationChannel",
          replayed: receipt.replayed
        }, status: receipt.replayed ? :ok : :created
      end

      # 402 rather than a validation error: the lead was fine, the buyer's balance
      # was not. The lead is retained and can be re-run after a top-up.
      def render_hold(result)
        render_error code: "insufficient_credits", message: result.error.to_sentence, status: :payment_required
      end

      # `pixel_id` is accepted because the reference snippet sends it, and then
      # ignored: the tenant comes from the key alone. The address and user agent
      # come from the connection for the same reason.
      def lead_attributes
        permitted = params.permit(:session_id, :pixel_id, :submitted_at, :form_dwell_ms, :page_url,
                                  fields: SUBMITTED_FIELDS)
        raise Errors::ValidationFailed, "session_id is required" if permitted[:session_id].blank?

        permitted.to_h.deep_symbolize_keys.merge(
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
      end
    end
  end
end
