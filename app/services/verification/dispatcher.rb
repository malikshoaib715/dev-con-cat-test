# frozen_string_literal: true

module Verification
  # The one place layer work is handed to the queue. Ingestion dispatches a new
  # run through here, and so will re-verification and the requeue-stuck task, so
  # there is a single definition of "start the layers for this run".
  #
  # Always called *after* the ingestion transaction has committed. Sidekiq's queue
  # lives in Redis, which is not our database: a job enqueued inside the
  # transaction can be picked up by a worker before the rows it needs exist.
  class Dispatcher < ApplicationService
    def initialize(run:)
      @run = run
    end

    def call
      jobs = outstanding_layer_keys.map { |layer_key| VerificationLayerJob.new(@run.id, layer_key) }
      # One round trip for the whole fan-out rather than ten.
      ActiveJob.perform_all_later(jobs)
      mark_running

      success(jobs.size)
    # Redis being unreachable must never cost us a lead.
    rescue *ApplicationJob::ENQUEUE_FAILURES => error
      undispatched(error)
    end

    private

    def outstanding_layer_keys
      @run.layer_results.outstanding.pluck(:layer_key)
    end

    # Conditional on the run still being `pending`, because the layers are already
    # in flight by now: a fast run can be claimed for finalization before this
    # update lands, and blindly writing `running` would drag it backwards.
    def mark_running
      VerificationRun.where(id: @run.id, status: "pending")
                     .update_all(status: "running", started_at: Time.current)
    end

    # The lead and its run are already committed, so nothing is lost. The run stays
    # `pending`, which is exactly what VerificationRun.stuck looks for, and it can
    # be driven again from the dashboard or the requeue task.
    def undispatched(error)
      Audit::Recorder.record!(
        Audit::Events::SYSTEM_ENQUEUE_FAILED,
        subject: @run.lead,
        payload: { run_id: @run.id, error_class: error.class.name, error_message: error.message }
      )

      failure("verification was accepted but could not be dispatched", code: :enqueue_failed)
    end
  end
end
