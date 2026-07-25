require "rails_helper"

# Retry policy lives in one place so no individual job can quietly invent its
# own. These are the two rules from CLAUDE.md §7.4.
RSpec.describe ApplicationJob do
  before do
    SpecProbeJob.attempts = 0
    SpecProbeJob.failure = nil
  end

  it "backs off and retries a vendor that is temporarily unavailable" do
    SpecProbeJob.failure = -> { raise Errors::ProviderUnavailable }

    # After the fourth attempt the error is re-raised rather than swallowed, so
    # a permanently dead provider surfaces instead of quietly disappearing.
    # ActiveJob's test helper rewraps that terminal exception.
    expect {
      perform_enqueued_jobs(only: SpecProbeJob) { SpecProbeJob.perform_later }
    }.to raise_error(Minitest::UnexpectedError, /ProviderUnavailable/)

    expect(SpecProbeJob.attempts).to eq(4)
  end

  it "gives up on a job whose records will never load, and records the loss" do
    SpecProbeJob.failure = lambda do
      raise ActiveRecord::RecordNotFound, "the lead is gone"
    rescue ActiveRecord::RecordNotFound
      raise ActiveJob::DeserializationError
    end

    perform_enqueued_jobs(only: SpecProbeJob) { SpecProbeJob.perform_later }

    expect(SpecProbeJob.attempts).to eq(3)
    events = ActsAsTenant.without_tenant { AuditEvent.of_type(Audit::Events::LAYER_ERRORED) }
    expect(events.count).to eq(1)
    expect(events.first.payload["job"]).to eq("SpecProbeJob")
  end
end
