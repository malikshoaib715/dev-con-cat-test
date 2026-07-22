# frozen_string_literal: true

# The one place retry and discard policy lives. Jobs themselves stay thin
# delivery shells: deserialize, set tenant and Current, delegate to a service.
class ApplicationJob < ActiveJob::Base
  # A vendor being down is transient; back off and try again before giving up.
  retry_on Errors::ProviderUnavailable, wait: :polynomially_longer, attempts: 4

  # We enqueue only after commit, so a job should never outrun its rows. This is
  # the backstop for operator mistakes and read replicas: retry briefly, then
  # record the loss rather than retrying forever.
  retry_on ActiveJob::DeserializationError, wait: 2.seconds, attempts: 3 do |job, error|
    Audit::Recorder.record!(
      Audit::Events::LAYER_ERRORED,
      payload: { job: job.class.name, error_class: error.class.name, error_message: error.message }
    )
  end
end
