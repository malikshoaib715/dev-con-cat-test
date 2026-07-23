# frozen_string_literal: true

# Runs one layer for one verification run. Ten of these are dispatched per lead and
# they race each other to finish; the last one to arrive triggers finalization.
#
# Sidekiq delivers at least once, so every step here is written to be safe to run
# twice: the row is claimed with a compare-and-set, the outcome is idempotent, and
# a redelivery after success finds a terminal row and does nothing.
class VerificationLayerJob < ApplicationJob
  queue_as :layers

  # A worker that died mid-layer would otherwise leave its row `processing`
  # forever, and the run would never finalize. After this long, a claim is assumed
  # abandoned and may be taken again.
  STALE_CLAIM_AFTER = 5.minutes

  ERROR_MESSAGE_LIMIT = 500

  # Declared here as well as in ApplicationJob so that exhausting the retries is a
  # *terminal outcome for this layer* rather than a lost job: the row is recorded
  # as errored and the run is allowed to move on. Rails matches the most recently
  # declared handler first, so this one wins for this job.
  retry_on Errors::ProviderUnavailable, wait: :polynomially_longer, attempts: 4 do |job, error|
    job.record_exhausted_provider(error)
  end

  def perform(run_id, layer_key)
    run = load_run(run_id)

    in_context(run) do
      row = claim(run, layer_key)
      # Somebody else is already on it, or it has already finished. Either way
      # there is nothing to do and nothing to complain about.
      next if row.nil?

      record_layer_outcome(run, row, Layers::Registry.processor_for(layer_key).call(lead: run.lead))
      check_for_completion(run)
    end
  rescue Errors::ProviderUnavailable
    # The claim has to be handed back before the exception continues, or the retry
    # would find the row still `processing`, decline to claim it, and quietly
    # succeed — the retries would all be no-ops and the run would never finish.
    release_claim(run_id, layer_key)
    raise # let retry_on own it; the hook above records the terminal outcome
  rescue StandardError => error
    # Terminal bookkeeping first, so a dead layer can never strand the run, then
    # re-raise so the bug stays visible in Sidekiq's retry set rather than being
    # quietly absorbed.
    record_layer_error(run_id, layer_key, error)
    raise
  end

  # The retry_on hook above, called once the vendor has been given every chance.
  # Public only because that hook is evaluated at the class level.
  def record_exhausted_provider(error)
    record_layer_error(*arguments, error)
  end

  private

  def load_run(run_id)
    # No tenant is set inside a worker; the run is what establishes one.
    ActsAsTenant.without_tenant { VerificationRun.includes(:lead, :account).find(run_id) }
  end

  def in_context(run, &block)
    ActsAsTenant.with_tenant(run.account) do
      Current.account = run.account
      # Correlates every event this job writes to the pixel session the lead came
      # from, which is what stitches the visit, the submission and the layers into
      # one timeline.
      Current.session_id = run.lead.session_id
      block.call
    end
  end

  # Compare-and-set, so a redelivery or a second worker cannot process one layer
  # twice. `update_all` deliberately skips callbacks and validations: it has to
  # compile to a single conditional UPDATE for the claim to mean anything.
  def claim(run, layer_key)
    claimed = claimable(run, layer_key).update_all(status: "processing", started_at: Time.current)
    return nil if claimed.zero?

    row = run.layer_results.find_by!(layer_key: layer_key)
    Audit::Recorder.record!(Audit::Events::LAYER_STARTED, subject: run.lead, payload: { layer_key: layer_key })
    row
  end

  def claimable(run, layer_key)
    run.layer_results
       .where(layer_key: layer_key)
       .where("status = 'pending' OR (status = 'processing' AND started_at < ?)", STALE_CLAIM_AFTER.ago)
  end

  # Only ever undoes this job's own claim: the status condition means a row that has
  # already reached a terminal state, or been re-claimed by somebody else, is left
  # exactly as it is.
  def release_claim(run_id, layer_key)
    run = load_run(run_id)

    ActsAsTenant.with_tenant(run.account) do
      run.layer_results
         .where(layer_key: layer_key, status: "processing")
         .update_all(status: "pending", started_at: nil)
    end
  end

  def record_layer_outcome(run, row, outcome)
    row.update!(
      status: outcome.status,
      verdict: outcome.verdict,
      panel_verdict: outcome.panel_verdict,
      detail: outcome.detail,
      # The signals ride along with the vendor's answer so the consensus engine has
      # one place to read and the certificate keeps both.
      raw_response: outcome.raw_response.merge("signals" => outcome.signals),
      completed_at: Time.current
    )

    Audit::Recorder.record!(
      outcome.not_applicable? ? Audit::Events::LAYER_SKIPPED : Audit::Events::LAYER_COMPLETED,
      subject: run.lead,
      payload: layer_payload(row)
    )
  end

  def record_layer_error(run_id, layer_key, error)
    run = load_run(run_id)

    in_context(run) do
      row = run.layer_results.find_by!(layer_key: layer_key)
      next if row.terminal?

      row.update!(
        status: "errored",
        panel_verdict: "warn",
        detail: "layer unavailable",
        error_class: error.class.name,
        error_message: error.message.to_s.truncate(ERROR_MESSAGE_LIMIT),
        completed_at: Time.current
      )
      Audit::Recorder.record!(
        Audit::Events::LAYER_ERRORED,
        subject: run.lead,
        payload: { layer_key: layer_key, error_class: error.class.name, error_message: row.error_message }
      )

      # An unavailable layer still counts as finished. Whether it costs the lead
      # its verdict is the consensus engine's decision, per the layer's
      # criticality — not this job's.
      check_for_completion(run)
    end
  end

  # Whichever layer finishes last claims the run for finalization, and only one of
  # them can. Chunk 3.3 dispatches FinalizeRunJob from this result, once there is a
  # consensus engine for it to run.
  def check_for_completion(run)
    Verification::CompletionGate.call(run: run)
  end

  def layer_payload(row)
    {
      layer_key: row.layer_key,
      status: row.status,
      verdict: row.verdict,
      panel_verdict: row.panel_verdict,
      detail: row.detail
    }
  end
end
