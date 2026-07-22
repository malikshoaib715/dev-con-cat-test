require "rails_helper"

RSpec.describe ConsensusVerdict do
  let(:account) { create(:account) }
  let(:run)     { create(:verification_run, account: account) }

  before { ActsAsTenant.current_tenant = account }

  it "allows only one verdict per run, so a raced finaliser cannot issue two" do
    create(:consensus_verdict, account: account, verification_run: run)

    expect { create(:consensus_verdict, account: account, verification_run: run) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "keeps the score inside the band the engine scores in" do
    expect(build(:consensus_verdict, account: account, score: 0)).to be_valid
    expect(build(:consensus_verdict, account: account, score: 100)).to be_valid
    expect(build(:consensus_verdict, account: account, score: 101)).not_to be_valid
    expect(build(:consensus_verdict, account: account, score: -1)).not_to be_valid
  end

  it "enforces the score band in the database as well" do
    verdict = create(:consensus_verdict, account: account, verification_run: run)

    expect { verdict.update_column(:score, 250) }
      .to raise_error(ActiveRecord::StatementInvalid, /consensus_verdicts_score_in_range/)
  end

  it "speaks only the three outcomes the assignment defines" do
    expect(described_class::VERDICTS).to eq(%w[accept review reject])
    expect(build(:consensus_verdict, account: account, verdict: "maybe")).not_to be_valid
  end

  it "keeps the policy that produced it, so the verdict stays explainable after a retune" do
    snapshot = { "thresholds" => { "accept" => 70 }, "weights" => { "anura" => { "suspect" => -15 } } }

    verdict = create(:consensus_verdict, account: account, verification_run: run, policy_snapshot: snapshot)

    expect(verdict.reload.policy_snapshot).to eq(snapshot)
  end

  it "records the layer that hard-stopped the lead when there was one" do
    verdict = create(:consensus_verdict, account: account, verification_run: run,
                                         verdict: "reject", score: 0, hard_stop_layer: "dnc")

    expect(verdict.hard_stop_layer).to eq("dnc")
    expect(verdict).to be_verdict_reject
  end
end
