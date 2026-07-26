# frozen_string_literal: true

module Verification
  # Drives a run nothing is working on any more (VerificationRun.stuck) to
  # completion, whatever stage its fan-out died at. Three cases, all idempotent:
  #
  #   layers still outstanding        -> dispatch them again (Dispatcher)
  #   claimed, finalizer never ran    -> enqueue the finalizer again
  #   all layers done, never claimed  -> claim through the gate, then enqueue
  #
  # The last two exist because the queue lives in Redis, not in our database: the
  # completion gate's claim commits before FinalizeRunJob is enqueued, so a queue
  # unreachable in that instant leaves a run that no layer retry will ever move —
  # re-dispatching layers finds nothing outstanding and recovers nothing.
  class Resumer < ApplicationService
    def initialize(run:)
      @run = run
    end

    def call
      return success(@run) if @run.completed?
      return Dispatcher.call(run: @run) if @run.outstanding_layer_results.exists?
      return enqueue_finalizer if @run.finalizing?

      claim = CompletionGate.call(run: @run)
      return claim if claim.failure?

      enqueue_finalizer
    end

    private

    def enqueue_finalizer
      FinalizeRunJob.perform_later(@run.id)
      success(@run)
    rescue *ApplicationJob::ENQUEUE_FAILURES => error
      Audit::Recorder.record!(
        Audit::Events::SYSTEM_ENQUEUE_FAILED,
        subject: @run.lead,
        payload: { run_id: @run.id, job: "FinalizeRunJob", error_class: error.class.name,
                   error_message: error.message }
      )
      failure("verification could not be handed to the queue", code: :enqueue_failed)
    end
  end
end
