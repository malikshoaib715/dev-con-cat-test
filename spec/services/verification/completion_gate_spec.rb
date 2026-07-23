require "rails_helper"

RSpec.describe Verification::CompletionGate do
  def build_run(statuses, run_status: "running")
    account = create(:account)
    as_tenant(account) do
      run = create(:verification_run, account: account, status: run_status)
      statuses.each_with_index do |status, index|
        create(:layer_result, account: account, verification_run: run,
                              layer_key: Layers::Registry.keys[index], status: status)
      end
      run
    end
  end

  it "refuses while any layer is still pending" do
    run = build_run(%w[completed pending])

    result = as_tenant(run.account) { described_class.call(run: run) }

    expect(result).to be_failure
    expect(result.code).to eq(:outstanding)
    expect(run.reload.status).to eq("running")
  end

  it "refuses while any layer is still being processed" do
    run = build_run(%w[completed processing])

    expect(as_tenant(run.account) { described_class.call(run: run) }.code).to eq(:outstanding)
  end

  # The three states that mean "this layer will never report" all count as done: a
  # layer nobody bought, a layer that did not apply, and a layer that broke.
  it "counts not_enabled, not_applicable and errored layers as finished" do
    run = build_run(%w[completed not_enabled not_applicable errored])

    result = as_tenant(run.account) { described_class.call(run: run) }

    expect(result).to be_success
    expect(run.reload.status).to eq("finalizing")
  end

  it "claims a run whose layers have all reported" do
    run = build_run(%w[completed completed])

    result = as_tenant(run.account) { described_class.call(run: run) }

    expect(result).to be_success
    expect(result.value).to eq(run)
    expect(run.reload.status).to eq("finalizing")
  end

  # Layers can finish before the dispatcher's flip to `running` has landed, and a
  # run whose work is done must not be stranded over which state it is in.
  it "claims a run still marked pending" do
    run = build_run(%w[completed completed], run_status: "pending")

    expect(as_tenant(run.account) { described_class.call(run: run) }).to be_success
    expect(run.reload.status).to eq("finalizing")
  end

  it "refuses a run somebody else has already claimed" do
    run = build_run(%w[completed completed], run_status: "finalizing")

    result = as_tenant(run.account) { described_class.call(run: run) }

    expect(result).to be_failure
    expect(result.code).to eq(:already_claimed)
  end

  it "refuses a run that has already been finalized" do
    run = build_run(%w[completed completed], run_status: "completed")

    expect(as_tenant(run.account) { described_class.call(run: run) }.code).to eq(:already_claimed)
  end

  describe "when the last layers finish at the same instant", :real_transactions do
    # This is the whole reason the class exists. Without the atomic claim both
    # callers would go on to finalize: two certificates for one lead, and credits
    # settled twice.
    it "hands the run to exactly one of them" do
      run = build_run(%w[completed completed])

      results = in_parallel(4, tenant: run.account) { described_class.call(run: run) }

      expect(results.count(&:success?)).to eq(1)
      expect(results.count { |result| result.code == :already_claimed }).to eq(3)
      expect(run.reload.status).to eq("finalizing")
    end
  end
end
