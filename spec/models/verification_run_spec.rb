require "rails_helper"

RSpec.describe VerificationRun do
  let(:account) { create(:account) }
  let(:lead)    { create(:lead, account: account) }

  before { ActsAsTenant.current_tenant = account }

  it "allows only one run per lead, so a re-post cannot start a second verification" do
    create(:verification_run, account: account, lead: lead)

    expect { create(:verification_run, account: account, lead: lead) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects a lifecycle state outside the known set, in Ruby and in the database" do
    run = build(:verification_run, account: account, lead: lead, status: "vibing")
    expect(run).not_to be_valid

    persisted = create(:verification_run, account: account, lead: lead)
    expect { persisted.update_column(:status, "vibing") }
      .to raise_error(ActiveRecord::StatementInvalid, /verification_runs_status_valid/)
  end

  it "refuses to reserve a negative number of credits" do
    run = build(:verification_run, account: account, lead: lead, reserved_credits: -1)

    expect(run).not_to be_valid
  end

  describe "#outstanding_layer_results" do
    it "counts only the layers that have yet to settle" do
      run = create(:verification_run, account: account, lead: lead)
      create(:layer_result, account: account, verification_run: run, layer_key: "anura",       status: "pending")
      create(:layer_result, account: account, verification_run: run, layer_key: "dnc",         status: "processing")
      create(:layer_result, account: account, verification_run: run, layer_key: "trustedform", status: "completed")
      create(:layer_result, account: account, verification_run: run, layer_key: "voice",       status: "not_enabled")

      expect(run.outstanding_layer_results.pluck(:layer_key)).to match_array(%w[anura dnc])
    end
  end

  # What "stuck" has to mean is "nothing is working on this any more". Status alone
  # cannot say that: a `running` run whose worker was killed mid-layer looks
  # exactly like one that is mid-flight, and Sidekiq only redelivers jobs that
  # raised — a killed worker's job is simply gone. Looking only at `pending` left
  # every one of those runs unrecoverable.
  describe ".stuck" do
    # `updated_at` matters as much as `created_at`: it is what the dispatcher and
    # the completion gate stamp, so it is how recently anything touched the run.
    def run_with_layer(status:, claim_status:, claimed_at: nil, touched_at: 1.hour.ago)
      run = create(:verification_run, account: account, status: status,
                                      created_at: touched_at, updated_at: touched_at)
      create(:layer_result, account: account, verification_run: run, layer_key: "anura",
                            status: claim_status, started_at: claimed_at)
      run
    end

    it "finds a run that was never dispatched" do
      never_dispatched = create(:verification_run, account: account, lead: lead, status: "pending",
                                                   created_at: 1.hour.ago, updated_at: 1.hour.ago)

      expect(described_class.stuck).to include(never_dispatched)
    end

    it "leaves a run that has only just been created alone" do
      just_created = create(:verification_run, account: account, status: "pending",
                                               created_at: 1.second.ago, updated_at: 1.second.ago)

      expect(described_class.stuck).not_to include(just_created)
    end

    it "finds a running run whose worker died holding a claim" do
      abandoned = run_with_layer(status: "running", claim_status: "processing", claimed_at: 1.hour.ago)

      expect(described_class.stuck).to include(abandoned)
    end

    # The half-dispatched fan-out: some jobs reached the queue, the rest did not,
    # and nothing will ever pick the remainder up.
    it "finds a running run whose layers were never picked up" do
      undispatched = run_with_layer(status: "running", claim_status: "pending")

      expect(described_class.stuck).to include(undispatched)
    end

    it "leaves a run alone while a worker still holds a fresh claim" do
      working = run_with_layer(status: "running", claim_status: "processing", claimed_at: 30.seconds.ago)


      expect(described_class.stuck).not_to include(working)
    end

    it "leaves a run that has already reached an outcome alone" do
      completed = run_with_layer(status: "completed", claim_status: "completed")

      expect(described_class.stuck).not_to include(completed)
    end

    # `finalizing` is a claim, not an outcome. The gate commits it before
    # FinalizeRunJob is enqueued, so an unreachable queue in that instant leaves a
    # run nothing will ever pick up — and finalization takes milliseconds.
    it "finds a run left claimed for finalization by a dispatch that never happened" do
      stranded = run_with_layer(status: "finalizing", claim_status: "completed")

      expect(described_class.stuck).to include(stranded)
    end

    it "leaves a run alone while it is actually being finalized" do
      finalizing = run_with_layer(status: "finalizing", claim_status: "completed",
                                  touched_at: 2.seconds.ago)

      expect(described_class.stuck).not_to include(finalizing)
    end
  end
end
