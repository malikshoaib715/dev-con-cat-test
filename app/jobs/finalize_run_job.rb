# frozen_string_literal: true

# Runs once per verification, dispatched by whichever layer job won the completion
# gate. A thin delivery shell: it establishes the tenant and the session the lead
# came from, and hands the work to Verification::Finalizer.
class FinalizeRunJob < ApplicationJob
  queue_as :finalize

  def perform(run_id)
    # No tenant is set inside a worker; the run is what establishes one.
    run = ActsAsTenant.without_tenant { VerificationRun.includes(:lead, :account).find(run_id) }

    ActsAsTenant.with_tenant(run.account) do
      Current.account = run.account
      Current.session_id = run.lead.session_id

      Verification::Finalizer.call(run: run)
    end
  end
end
