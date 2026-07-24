# frozen_string_literal: true

module Leads
  # Accepts a submitted lead: one transaction that either produces a funded run
  # ready to verify, or a retained lead nobody has been charged for. Never a
  # half-built pipeline.
  #
  # The account comes from the pixel, which came from the key. Nothing in the
  # payload can influence which tenant a lead lands in.
  class IngestionService < ApplicationService
    # `same_submitter` is what the caller has proved about itself, and it decides
    # whether a live-activity capability may be issued (see LeadsController).
    Receipt = Data.define(:lead, :replayed, :same_submitter)

    IDENTITY_FIELDS = %i[first_name last_name].freeze

    def initialize(pixel:, attributes:)
      @pixel = pixel
      @attributes = attributes
    end

    def call
      return replay if already_submitted
      raise Errors::ValidationFailed, "this pixel has no enabled layers" if effective_layer_keys.empty?

      accept
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
      # A concurrent submission for the same session won. Handled out here because
      # the failed insert has already aborted the transaction.
      raise unless duplicate_session?(error)

      replay
    end

    private

    # Which of the two exceptions arrives is pure timing, so both have to be read
    # as the same thing: if both submissions validate before either commits, the
    # unique index arbitrates and raises RecordNotUnique; if the winner commits in
    # between, the model's uniqueness validation gets there first and raises
    # RecordInvalid. Anything else — a genuinely invalid lead, some other unique
    # index — is a real failure and is re-raised.
    def duplicate_session?(error)
      return false unless already_submitted
      return true if error.is_a?(ActiveRecord::RecordNotUnique)

      error.record.is_a?(Lead) && error.record.errors.of_kind?(:session_id, :taken)
    end

    # Everything or nothing: a crash between the lead, the run, the layer rows and
    # the money must not leave any of them behind.
    #
    # Note that the *hold* path commits too. Running out of credits is a business
    # outcome, not a failure to record what happened, and the lead has to survive it.
    def accept
      outcome = nil

      ApplicationRecord.transaction do
        lock_account
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

    # The account row is locked before anything that references it. Every insert
    # below takes a FOR KEY SHARE lock on this same row through its foreign key,
    # and the reservation then wants FOR UPDATE — so taking the account lock last
    # would let two submissions for one account each hold a key-share lock while
    # waiting for the other's, which Postgres resolves by killing one of them and
    # losing that lead. First lock taken, every time, is the rule that avoids it.
    def lock_account
      @pixel.account.lock!
    end

    def create_lead
      fields = submitted_fields

      @pixel.leads.create!(
        account: @pixel.account,
        # Seeds and specs only, and never reachable from the pixel endpoint: the
        # twelve fixture leads have to keep their own ids or the gateway cannot
        # look their recorded vendor answers up. Left to HasPublicId otherwise.
        public_id: @attributes[:public_id],
        session_id: @attributes.fetch(:session_id),
        **fields.slice(*IDENTITY_FIELDS),
        # `presence` so a field the visitor left as whitespace is stored as
        # absent rather than as a string that looks like an address but matches
        # nothing. The exact submission survives in raw_payload either way.
        email: fields[:email].presence,
        email_normalized: Normalizer.email(fields[:email]),
        phone: fields[:phone].presence,
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

      success(Receipt.new(lead: lead, replayed: false, same_submitter: true))
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

      success(Receipt.new(lead: lead, replayed: true, same_submitter: same_identity_as?(lead)))
    end

    # Session ids are generated on the page and are guessable — the reference
    # pixel builds one from Date.now and Math.random — so knowing one cannot by
    # itself be enough to be handed a capability for the lead behind it. A form
    # that was double-clicked or retried by the browser resubmits the same
    # identity and is unaffected; a guessed session id does not know it.
    def same_identity_as?(lead)
      fields = submitted_fields

      Normalizer.email(fields[:email]) == lead.email_normalized &&
        Normalizer.phone(fields[:phone]) == lead.phone_normalized
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
