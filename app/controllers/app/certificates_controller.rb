# frozen_string_literal: true

module App
  # The buyer's own copy of every consent certificate they hold. The public page
  # at /verify/:public_id shows the same evidence to anyone with the link; this
  # one is the list they can work from.
  class CertificatesController < BaseController
    include Pagy::Backend

    def index
      certificates = policy_scope(current_account.consent_certificates).recent_first.includes(:lead)
      @pagy, @certificates = pagy(certificates)
    end

    def show
      @certificate = current_account.consent_certificates.find_by!(public_id: params[:id])
      authorize @certificate
      # Recomputed on every view rather than stored: a stored answer would be one
      # more thing an editor could change to match.
      @report = Certificates::Verifier.call(certificate: @certificate)
    end
  end
end
