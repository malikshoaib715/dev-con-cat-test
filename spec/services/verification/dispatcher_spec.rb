require "rails_helper"

RSpec.describe Verification::Dispatcher do
  def build_run(status: "pending")
    account = create(:account)
    as_tenant(account) do
      run = create(:verification_run, account: account, status: status)
      create(:layer_result, account: account, verification_run: run, layer_key: "anura", status: "pending")
      create(:layer_result, account: account, verification_run: run, layer_key: "dnc", status: "pending")
      create(:layer_result, account: account, verification_run: run, layer_key: "voice",
                            status: "not_enabled", panel_verdict: "skip")
      run
    end
  end

  def dispatch(run)
    as_tenant(run.account) { described_class.call(run: run) }
  end

  describe "handing the layers to the queue" do
    let(:run) { build_run }

    it "enqueues one job per layer that still has to report" do
      expect { dispatch(run) }.to change { enqueued_jobs.size }.by(2)

      expect(enqueued_jobs.map { |job| job[:args].last }).to match_array(%w[anura dnc])
      expect(enqueued_jobs.map { |job| job[:job] }.uniq).to eq([ VerificationLayerJob ])
    end

    it "enqueues nothing for a layer the account never bought" do
      dispatch(run)

      expect(enqueued_jobs.map { |job| job[:args].last }).not_to include("voice")
    end

    it "reports how many were dispatched" do
      expect(dispatch(run).value).to eq(2)
    end

    it "marks the run running so the panel knows work is under way" do
      dispatch(run)

      expect(run.reload.status).to eq("running")
      expect(run.started_at).to be_present
    end
  end

  # The layers are already in flight by the time the run is marked running, so a
  # fast run can be claimed for finalization first. Writing `running` unconditionally
  # would drag it backwards and it would never be finalized.
  describe "a run that has already moved on" do
    it "does not drag a finalizing run back to running" do
      run = build_run(status: "finalizing")

      dispatch(run)

      expect(run.reload.status).to eq("finalizing")
    end

    it "does not drag a completed run back to running" do
      run = build_run(status: "completed")

      dispatch(run)

      expect(run.reload.status).to eq("completed")
    end
  end

  describe "when the queue is unreachable" do
    let(:run) { build_run }

    before { allow(ActiveJob).to receive(:perform_all_later).and_raise(RedisClient::CannotConnectError, "no redis") }

    it "fails with a code the caller can act on rather than raising" do
      result = dispatch(run)

      expect(result).to be_failure
      expect(result.code).to eq(:enqueue_failed)
    end

    # Left pending on purpose: that is what marks it recoverable.
    it "leaves the run exactly where the requeue task will find it" do
      dispatch(run)

      expect(run.reload.status).to eq("pending")
      expect(run.started_at).to be_nil
    end

    it "records why it was never dispatched" do
      dispatch(run)

      event = ActsAsTenant.without_tenant { AuditEvent.of_type(Audit::Events::SYSTEM_ENQUEUE_FAILED).sole }
      expect(event.subject_id).to eq(run.lead_id)
      expect(event.payload).to include("run_id" => run.id, "error_class" => "RedisClient::CannotConnectError")
    end

    it "also survives the other client library's errors, since both are in the stack" do
      allow(ActiveJob).to receive(:perform_all_later).and_raise(Redis::CannotConnectError, "no redis")

      expect(dispatch(run).code).to eq(:enqueue_failed)
    end
  end
end
