# frozen_string_literal: true

module Leads
  # Drives a lead's verification again — the promise ingestion makes when it keeps
  # a lead it could not afford to verify, and the repair for a run that reached the
  # database but never reached the queue.
  #
  # Two cases, and only two. A held lead has no run at all (ingestion discards it
  # so nothing can mistake it for work waiting to be dispatched), so it needs
  # funding and a new one. A stuck run already has everything except a worker, so
  # it only needs dispatching — which is idempotent, and picks up exactly the
  # layers still outstanding. Anything else is a lead nobody should be spending
  # credits on twice.
  class Reverification < ApplicationService
    def initialize(lead:)
      @lead = lead
    end

    def call
      # A run nothing is working on any more (VerificationRun.stuck) — the
      # Redis-was-down case, where the rows committed and some hand-off to the
      # queue never happened. The Resumer restarts it from whichever stage was
      # lost: outstanding layers, or a finalization that never reached a worker.
      resumable_run = @lead.stuck_run
      return resume(resumable_run) if resumable_run

      return not_reverifiable unless @lead.on_hold_insufficient_credits?
      return no_layers if layer_keys.empty?

      start_new_run
    end

    private

    # Everything or nothing, exactly as at ingestion: an account debited for a run
    # that did not commit would be a charge for work nobody can point at.
    def start_new_run
      outcome = nil

      ApplicationRecord.transaction do
        # Same lock ordering as ingestion and settlement: the account row first.
        @lead.account.lock!
        run = Verification::RunCreator.call(lead: @lead, effective_layer_keys: layer_keys).value
        reservation = Credits::Reservation.call(account: @lead.account, run: run, layer_keys: layer_keys)

        outcome = reservation.failure? ? still_held(run, reservation) : started(run)
      end

      outcome.failure? ? outcome : dispatch(outcome.value)
    end

    # The top-up was not enough. The lead stays exactly as it was — held, funded by
    # nobody — and the run is discarded again rather than left as an unfunded
    # shell.
    def still_held(run, reservation)
      run.destroy!
      failure(reservation.error, code: :insufficient_credits)
    end

    def started(run)
      @lead.update!(status: "verifying", verdict: nil)
      Audit::Recorder.record!(
        Audit::Events::VERIFICATION_STARTED,
        subject: @lead,
        payload: { run_id: run.id, layer_keys: layer_keys, reverified: true }
      )

      success(run)
    end

    def dispatch(run)
      result = Verification::Dispatcher.call(run: run)
      result.failure? ? result : success(run)
    end

    def resume(run)
      result = Verification::Resumer.call(run: run)
      result.failure? ? result : success(run)
    end

    def not_reverifiable
      failure("this lead is not waiting to be verified", code: :not_reverifiable)
    end

    def no_layers
      failure("this lead's pixel runs no layers, so there is nothing to verify",
              code: :no_enabled_layers)
    end

    def layer_keys
      @layer_keys ||= @lead.pixel.effective_layer_keys
    end
  end
end
