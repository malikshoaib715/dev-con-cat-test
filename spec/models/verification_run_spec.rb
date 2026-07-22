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

  describe ".stuck" do
    it "finds runs that were never dispatched, so they can be re-driven" do
      never_dispatched = create(:verification_run, account: account, lead: lead,
                                                   status: "pending", created_at: 1.hour.ago)
      create(:verification_run, account: account, status: "pending", created_at: 1.second.ago)
      create(:verification_run, account: account, status: "running", created_at: 1.hour.ago)

      expect(described_class.stuck).to contain_exactly(never_dispatched)
    end
  end
end
