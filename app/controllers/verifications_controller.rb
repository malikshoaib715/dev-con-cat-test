# frozen_string_literal: true

# The public consent verifier. A certificate is worth nothing if only its owner
# can check it, so this page needs no session: the unguessable `cert_…` id is the
# capability, and everything it shows is already evidence the buyer would hand
# over to prove consent.
#
# Deliberately outside every tenant scope for the same reason — the regulator
# reading it does not have an account here.
class VerificationsController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :set_current_tenant

  def show
    @certificate = find_certificate
    @report = Certificates::Verifier.call(certificate: @certificate)

    respond_to do |format|
      format.html
      format.json { render json: report_json }
    end
  end

  private

  def find_certificate
    ActsAsTenant.without_tenant { ConsentCertificate.find_by!(public_id: params[:public_id]) }
  end

  def report_json
    {
      certificate_id: @certificate.public_id,
      status: @report.status,
      verdict: @certificate.verdict,
      issued_at: @certificate.issued_at,
      sequence_number: @certificate.sequence_number,
      evidence_hash: @certificate.evidence_hash,
      recomputed_hash: @report.expected_hash,
      previous_hash: @certificate.previous_hash,
      hash_valid: @report.hash_valid,
      chain_valid: @report.chain_valid,
      evidence: @certificate.evidence
    }
  end
end
