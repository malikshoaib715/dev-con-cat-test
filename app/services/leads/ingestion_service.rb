# frozen_string_literal: true

module Leads
  # Accepts a submitted lead: one transaction that either produces a funded run
  # ready to verify, or a retained lead nobody has been charged for. Never a
  # half-built pipeline.
  #
  # The account comes from the pixel, which came from the key. Nothing in the
  # payload can influence which tenant a lead lands in.
  class IngestionService < ApplicationService
    Receipt = Data.define(:lead, :replayed)

    IDENTITY_FIELDS = %i[first_name last_name].freeze

    def initialize(pixel:, attributes:)
      @pixel = pixel
      @attributes = attributes
    end

    def call
      return replay if already_submitted
      raise Errors::ValidationFailed, "this pixel has no enabled layers" if effective_layer_keys.empty?

      accept
    rescue ActiveRecord::RecordNotUnique
      # A concurrent submission for the same session won the insert. The database
      # settled it; the loser reports what the winner created. Handled out here
      # because the failed insert has already aborted the transaction.
      replay
    end

    private

    # Everything or nothing: a crash between the lead, the run, the layer rows and
    # the money must not leave any of them behind.
    #
    # Note that the *hold* path commits too. Running out of credits is a business
    # outcome, not a failure to record what happened, and the lead has to survive it.
    def accept
      outcome = nil

      ApplicationRecord.transaction do
        lead = create_lead
        record_receipt(lead)
        run = Verification::RunCreator.call(lead: lead, effective_layer_keys: effective_layer_keys).value
        reservation = Credits::Reservation.call(account: @pixel.account, run: run,
                                                layer_keys: effective_layer_keys)

        outcome = reservation.failure? ? hold(lead, run, reservation) : accepted(lead, run)
      end

      return outcome if outcome.failure?

      dispatch(outcome.value.lead)
      outcome
    end

    def create_lead
      fields = submitted_fields

      @pixel.leads.create!(
        account: @pixel.account,
        session_id: @attributes.fetch(:session_id),
        **fields.slice(*IDENTITY_FIELDS),
        email: fields[:email],
        email_normalized: Normalizer.email(fields[:email]),
        phone: fields[:phone],
        phone_normalized: Normalizer.phone(fields[:phone]),
        # Taken from the connection, never the body: the submit address is compared
        # against the address the visit beacon was fired from.
        ip_address: @attributes[:ip_address],
        user_agent: @attributes[:user_agent],
        page_url: @attributes[:page_url],
        form_dwell_ms: @attributes[:form_dwell_ms],
        submitted_at: @attributes[:submitted_at].presence || Time.current,
        status: "received",
        raw_payload: fields
      )
    end

    # An account that cannot afford a verification never starts one, but its lead is
    # kept: the buyer tops up and re-runs it rather than losing the person who filled
    # the form in. The run and its layer rows are discarded so that nothing can later
    # mistake this for work waiting to be dispatched.
    #
    # Why the run existed at all: the reservation writes a ledger entry against it,
    # and the ledger's uniqueness guard is per run.
    def hold(lead, run, reservation)
      run.destroy!
      lead.update!(status: "on_hold_insufficient_credits")
      Audit::Recorder.record!(Audit::Events::LEAD_ON_HOLD, subject: lead,
                                                           payload: { reason: "insufficient_credits" })

      failure(reservation.error, code: :insufficient_credits)
    end

    def accepted(lead, run)
      lead.update!(status: "verifying")
      Audit::Recorder.record!(
        Audit::Events::VERIFICATION_STARTED,
        subject: lead,
        payload: { run_id: run.id, layer_keys: effective_layer_keys }
      )

      success(Receipt.new(lead: lead, replayed: false))
    end

    def record_receipt(lead)
      Audit::Recorder.record!(
        Audit::Events::LEAD_RECEIVED,
        subject: lead,
        payload: { page_url: lead.page_url, form_dwell_ms: lead.form_dwell_ms }
      )
    end

    # Outside the transaction, deliberately (see Verification::Dispatcher). A
    # dispatch that fails is not an ingestion that failed: the caller is still told
    # the lead was accepted.
    def dispatch(lead)
      Verification::Dispatcher.call(run: lead.verification_run)
    end

    # A resubmission of the same form — a double-click, a retried beacon, a reloaded
    # confirmation page — is answered with the lead that already exists rather than
    # charged for twice.
    def replay
      lead = @pixel.leads.find_by!(session_id: @attributes.fetch(:session_id))
      Audit::Recorder.record!(Audit::Events::LEAD_REPLAY_DETECTED, subject: lead,
                                                                   payload: { session_id: lead.session_id })

      success(Receipt.new(lead: lead, replayed: true))
    end

    def already_submitted
      @pixel.leads.exists?(session_id: @attributes.fetch(:session_id))
    end

    def submitted_fields
      (@attributes[:fields] || {}).symbolize_keys
    end

    # The account's plan intersected with what this pixel was configured to run.
    def effective_layer_keys
      @effective_layer_keys ||= @pixel.effective_layer_keys
    end
  end
end
