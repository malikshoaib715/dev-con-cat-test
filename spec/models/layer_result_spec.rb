require "rails_helper"

RSpec.describe LayerResult do
  let(:account) { create(:account) }
  let(:run)     { create(:verification_run, account: account) }

  before { ActsAsTenant.current_tenant = account }

  it "keeps the three rubric states distinguishable from the lifecycle states" do
    expect(described_class::STATUSES).to include("not_enabled", "not_applicable", "completed")
    expect(described_class::STATUSES).to include("pending", "processing", "errored")
  end

  it "treats settled outcomes as terminal and in-flight ones as not" do
    expect(build(:layer_result, status: "not_enabled")).to be_terminal
    expect(build(:layer_result, status: "not_applicable")).to be_terminal
    expect(build(:layer_result, status: "completed")).to be_terminal
    expect(build(:layer_result, status: "errored")).to be_terminal
    expect(build(:layer_result, status: "pending")).not_to be_terminal
    expect(build(:layer_result, status: "processing")).not_to be_terminal
  end

  it "allows only one row per layer per run, so a retried job cannot duplicate work" do
    create(:layer_result, account: account, verification_run: run, layer_key: "anura")
    duplicate = build(:layer_result, account: account, verification_run: run, layer_key: "anura")

    expect(duplicate).not_to be_valid
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects a layer key that is not in the canonical registry" do
    result = build(:layer_result, account: account, verification_run: run, layer_key: "trusted_form")

    expect(result).not_to be_valid
  end

  it "exposes the panel label from the registry rather than a second spelling" do
    result = build(:layer_result, layer_key: "duplicate_detection")

    expect(result.label).to eq("Duplicate")
  end
end
