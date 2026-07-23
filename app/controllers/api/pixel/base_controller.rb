# frozen_string_literal: true

module Api
  module Pixel
    # The public, cross-origin surface. Every failure leaves through one
    # envelope carrying a machine-readable code and the request id, so a buyer
    # debugging an embed has something to quote and we have something to grep.
    class BaseController < ActionController::API
      include RequestContext

      # Rails matches rescue_from handlers last-registered-first, so the catch-all
      # is declared first and every specific mapping below overrides it.
      rescue_from StandardError,                     with: :render_internal_error
      rescue_from ActiveRecord::RecordNotFound,      with: :render_not_found
      rescue_from ActiveRecord::RecordInvalid,       with: :render_record_invalid
      rescue_from ActionController::ParameterMissing, with: :render_unprocessable
      rescue_from Errors::ValidationFailed,          with: :render_unprocessable
      rescue_from Errors::InsufficientCredits,       with: :render_payment_required
      rescue_from Errors::OriginNotAllowed,          with: :render_origin_not_allowed
      rescue_from Errors::PixelNotAuthorized,        with: :render_unauthorized

      # Correlation first, so even a rejected call is traceable to the session
      # that made it; then who is calling; then whether they may call from there.
      before_action :correlate_session
      before_action :authenticate_pixel!
      before_action :enforce_origin!

      private

      def current_pixel
        Current.pixel
      end

      def correlate_session
        Current.session_id = params[:session_id].presence
      end

      # The account is derived from the key and nothing else. A payload may carry
      # any `pixel_id` or `account_id` it likes; none of it is read here, which is
      # what makes posting a lead into someone else's account impossible.
      #
      # `::Pixel` is deliberate: inside `Api::Pixel` a bare `Pixel` resolves to
      # this namespace, not the model.
      def authenticate_pixel!
        pixel = find_pixel_by_key
        raise Errors::PixelNotAuthorized if pixel.nil?

        Current.pixel = pixel
        Current.account = pixel.account
        ActsAsTenant.current_tenant = pixel.account
      end

      def find_pixel_by_key
        public_key = request.headers[PixelRequest::KEY_HEADER].presence
        return nil if public_key.nil?

        # No tenant is set yet: the key is what establishes one.
        ActsAsTenant.without_tenant { ::Pixel.active.find_by(public_key: public_key) }
      end

      # A key is public by nature — it ships inside a script tag on a public page.
      # The domain allowlist is what stops a stolen snippet from being run from
      # somewhere its owner never authorised.
      def enforce_origin!
        origin = request.origin.presence || request.referer.presence
        raise Errors::OriginNotAllowed unless current_pixel.allows_origin?(origin)
      end

      def render_error(code:, message:, status:)
        render json: {
          error: { code: code, message: message, request_id: Current.request_id }
        }, status: status
      end

      def render_unauthorized(error)
        render_error code: error.code, message: "Unknown or inactive pixel key.", status: :unauthorized
      end

      def render_origin_not_allowed(error)
        render_error code: error.code, message: "This origin is not allowed for this pixel.", status: :forbidden
      end

      def render_payment_required(error)
        render_error code: error.code, message: error.message, status: :payment_required
      end

      def render_unprocessable(error)
        render_error code: error.code, message: error.message, status: :unprocessable_content
      end

      def render_record_invalid(error)
        render_error code: "validation_failed", message: error.record.errors.full_messages.to_sentence,
                     status: :unprocessable_content
      end

      def render_not_found(_error)
        render_error code: "not_found", message: "Not found.", status: :not_found
      end

      # Internals never leak to a buyer's landing page; the request id is the
      # handle for both sides of the conversation.
      def render_internal_error(error)
        Rails.logger.error("[#{Current.request_id}] #{error.class}: #{error.message}")
        Rails.logger.error(error.backtrace&.first(20)&.join("\n"))
        Audit::Recorder.record!(
          Audit::Events::API_REQUEST_REJECTED,
          payload: { error_class: error.class.name, path: request.path }
        )
        render_error code: "internal_error", message: "Something went wrong.", status: :internal_server_error
      end
    end
  end
end
