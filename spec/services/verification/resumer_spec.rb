require "rails_helper"

RSpec.describe Verification::Resumer do
  def build_run(status:, layer_status: "completed")
    account = create(:account)
    as_tenant(account) do
      run = create(:verification_run, account: account, status: status)
      create(:layer_result, account: account, verification_run: run, layer_key: "anura",
                            status: layer_status, panel_verdict: layer_status == "completed" ? "pass" : nil)
      create(:layer_result, account: account, verification_run: run, layer_key: "dnc",
                            status: "completed", panel_verdict: "pass")
      run
    end
  end

  def resume(run)
    as_tenant(run.account) { described_class.call(run: run) }
  end

  context "when layers never reached the queue" do
    it "dispatches exactly the layers still outstanding" do
      run = build_run(status: "pending", layer_status: "pending")

      expect { resume(run) }.to change { enqueued_jobs.size }.by(1)

      expect(enqueued_jobs.sole).to include(job: VerificationLayerJob)
      expect(enqueued_jobs.sole[:args]).to eq([ run.id, "anura" ])
    end
  end

  # The completion gate's claim commits before FinalizeRunJob is enqueued, so a
  # queue unreachable in that instant leaves a claimed run with nothing coming.
  # Re-dispatching layers cannot recover it — nothing is outstanding.
  context "when the run was claimed but the finalizer never ran" do
    it "enqueues the finalizer again" do
      run = build_run(status: "finalizing")

      expect { resume(run) }.to change { enqueued_jobs.size }.by(1)

      expect(enqueued_jobs.sole).to include(job: FinalizeRunJob, args: [ run.id ])
    end
  end

  context "when every layer finished but nothing ever claimed the run" do
    it "claims it through the gate and enqueues the finalizer" do
      run = build_run(status: "running")

      result = resume(run)

      expect(result).to be_success
      expect(run.reload.status).to eq("finalizing")
      expect(enqueued_jobs.sole).to include(job: FinalizeRunJob, args: [ run.id ])
    end
  end

  context "when the run already completed" do
    it "does nothing, successfully" do
      run = build_run(status: "completed")

      result = resume(run)

      expect(result).to be_success
      expect(enqueued_jobs).to be_empty
    end
  end

  context "when the queue is still unreachable" do
    it "records the failed hand-off and reports failure rather than raising" do
      run = build_run(status: "finalizing")
      allow(FinalizeRunJob).to receive(:perform_later).and_raise(RedisClient::CannotConnectError, "down")

      result = resume(run)

      expect(result).to be_failure
      expect(result.code).to eq(:enqueue_failed)
      event = as_tenant(run.account) do
        AuditEvent.of_type(Audit::Events::SYSTEM_ENQUEUE_FAILED).last
      end
      expect(event.payload).to include("job" => "FinalizeRunJob", "run_id" => run.id)
    end
  end
end
