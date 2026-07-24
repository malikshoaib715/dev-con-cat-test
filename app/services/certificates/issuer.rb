# frozen_string_literal: true

module Certificates
  # The artifact a buyer would hand a regulator: what was checked, what each check
  # answered, what was decided, and under exactly which policy.
  #
  # Two properties matter more than anything else here. The evidence is hashed
  # canonically, so the digest survives a jsonb round trip. And each certificate
  # names its predecessor's hash, so editing one historical record breaks every
  # later link rather than only its own — a buyer cannot quietly improve last
  # month's verdicts.
  class Issuer < ApplicationService
    def initialize(run:, consensus_verdict:)
      @run = run
      @consensus_verdict = consensus_verdict
    end

    def call
      success(issue)
    rescue ActiveRecord::RecordNotUnique
      # A redelivered finalizer. The unique index on verification_run_id is what
      # makes a second issuance impossible rather than merely unlikely.
      success(account.consent_certificates.find_by!(verification_run_id: @run.id))
    end

    private

    # The lock serialises issuance for this account, which is what keeps the
    # sequence gapless and every previous_hash pointing at the certificate that
    # really preceded it.
    def issue
      certificate = account.with_lock { create_certificate }
      record_audit(certificate)
      certificate
    end

    def create_certificate
      previous = account.consent_certificates.chain_order.last

      # By foreign key, not by association object, and this matters. Assigning
      # `verification_run: @run` attaches the new certificate to that run's has_one
      # — so when the insert loses the unique index to a certificate that already
      # exists, the *failed* record stays hanging off the caller's run and the next
      # `run.save` autosaves it, raising the same violation somewhere else entirely.
      # A redelivered finalizer could then never close its run.
      account.consent_certificates.create!(
        lead_id: lead.id,
        verification_run_id: @run.id,
        verdict: @consensus_verdict.verdict,
        evidence: evidence,
        evidence_hash: CanonicalJson.hexdigest(evidence),
        previous_hash: previous&.evidence_hash,
        sequence_number: (previous&.sequence_number || 0) + 1,
        trustedform_reference: trustedform_reference,
        issued_at: issued_at
      )
    end

    # Round-tripped through JSON before it is hashed or stored, so that times and
    # symbols become the exact strings that will come back out of jsonb. Hashing
    # the Ruby objects instead would produce a digest the database can never
    # reproduce.
    def evidence
      @evidence ||= JSON.parse(JSON.generate(raw_evidence))
    end

    def raw_evidence
      {
        lead: lead_evidence,
        pixel: pixel_evidence,
        session: session_evidence,
        layers: layers_evidence,
        consensus: consensus_evidence,
        policy_snapshot: @consensus_verdict.policy_snapshot,
        trustedform: trustedform_evidence,
        issued_at: issued_at,
        engine_version: Consensus::Policy::ENGINE_VERSION
      }
    end

    def lead_evidence
      {
        public_id: lead.public_id, first_name: lead.first_name, last_name: lead.last_name,
        email: lead.email, email_normalized: lead.email_normalized,
        phone: lead.phone, phone_normalized: lead.phone_normalized,
        submitted_at: lead.submitted_at, form_dwell_ms: lead.form_dwell_ms,
        user_agent: lead.user_agent
      }
    end

    def pixel_evidence
      { public_id: lead.pixel.public_id, page_url: lead.page_url }
    end

    # The address the page was opened from against the address the form was posted
    # from. A consent record that cannot say where the person was is worth less
    # than one that can.
    def session_evidence
      { session_id: lead.session_id, visit_ip: visit&.ip_address, submit_ip: lead.ip_address }
    end

    # All ten layers, every time. A buyer reading this must be able to tell a check
    # that passed from one the account never bought, one that had nothing to judge,
    # and one that could not answer — collapsing those into silence is the exact
    # misrepresentation a consent record exists to prevent.
    def layers_evidence
      Layers::Registry.keys.index_with { |layer_key| layer_evidence(rows_by_key[layer_key]) }
    end

    def layer_evidence(row)
      return { status: "missing" } if row.nil?

      {
        status: row.status, verdict: row.verdict, panel_verdict: row.panel_verdict,
        detail: row.detail, signals: Array(row.raw_response["signals"]),
        score_delta: row.score_delta, error_class: row.error_class,
        completed_at: row.completed_at
      }
    end

    def consensus_evidence
      {
        verdict: @consensus_verdict.verdict, score: @consensus_verdict.score,
        reasons: @consensus_verdict.reasons, flags: @consensus_verdict.flags,
        hard_stop_layer: @consensus_verdict.hard_stop_layer
      }
    end

    # The consent proof itself, kept beside the layer's own answer about it: the
    # reference alone does not say whether it matched the person who submitted.
    def trustedform_evidence
      row = rows_by_key["trustedform"]

      {
        reference: trustedform_reference,
        status: row&.verdict,
        matches_phone: row&.raw_response&.dig("matches_phone"),
        matches_email: row&.raw_response&.dig("matches_email"),
        expires_at: row&.raw_response&.dig("expires_at")
      }
    end

    def trustedform_reference
      lead.raw_payload["trusted_form_cert_url"]
    end

    # One timestamp, read twice: the column and the hashed evidence have to agree
    # about when this certificate was issued, or the document says one thing and
    # the record another.
    def issued_at
      @issued_at ||= Time.current
    end

    def rows_by_key
      @rows_by_key ||= @run.layer_results.index_by(&:layer_key)
    end

    def visit
      return @visit if defined?(@visit)

      @visit = Visit.find_by(pixel_id: lead.pixel_id, session_id: lead.session_id)
    end

    def record_audit(certificate)
      Audit::Recorder.record!(
        Audit::Events::CERTIFICATE_ISSUED,
        subject: lead,
        account: account,
        payload: { certificate_id: certificate.public_id, sequence_number: certificate.sequence_number,
                   evidence_hash: certificate.evidence_hash }
      )
    end

    def account
      @account ||= @run.account
    end

    def lead
      @lead ||= @run.lead
    end
  end
end
