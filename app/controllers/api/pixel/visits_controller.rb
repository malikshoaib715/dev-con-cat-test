# frozen_string_literal: true

module Api
  module Pixel
    # The site-visit beacon, fired once on page load before there is any lead.
    class VisitsController < BaseController
      # Field focus/blur churn is rendered client-side and only ever reaches us
      # as this summary, so keystroke traffic can never flood the audit spine.
      INTERACTION_KEYS = %i[name action at].freeze

      def create
        result = Visits::Recorder.call(
          pixel: current_pixel,
          attributes: beacon_attributes,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )

        render json: { session_id: result.value.session_id }, status: :accepted
      end

      private

      # `pixel_id` is accepted because the reference snippet sends it, and then
      # deliberately ignored: the pixel is identified by its key (see
      # BaseController#authenticate_pixel!).
      def beacon_attributes
        attributes = params.permit(:session_id, :pixel_id, :page_url, :referrer, :started_at,
                                   interactions: INTERACTION_KEYS)
        raise Errors::ValidationFailed, "session_id is required" if attributes[:session_id].blank?

        attributes.to_h.symbolize_keys
      end
    end
  end
end
