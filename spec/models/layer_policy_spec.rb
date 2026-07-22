require "rails_helper"

RSpec.describe LayerPolicy do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  before { ActsAsTenant.current_tenant = account }

  it "accepts only canonical layer keys, in Ruby and in the database" do
    expect(build(:layer_policy, account: account, layer_key: "duplicate")).not_to be_valid

    policy = create(:layer_policy, account: account, layer_key: "duplicate_detection")
    expect { policy.update_column(:layer_key, "duplicate") }
      .to raise_error(ActiveRecord::StatementInvalid, /layer_policies_layer_key_canonical/)
  end

  it "holds one decision per layer per account" do
    create(:layer_policy, account: account, layer_key: "anura")
    duplicate = build(:layer_policy, account: account, layer_key: "anura")

    expect(duplicate).not_to be_valid
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "lets two accounts each hold their own decision on the same layer" do
    create(:layer_policy, account: account, layer_key: "voice", enabled: false)

    theirs = as_tenant(other_account) do
      create(:layer_policy, account: other_account, layer_key: "voice", enabled: true)
    end

    expect(theirs).to be_persisted
  end

  it "lists only what the account actually pays for" do
    paid = create(:layer_policy, account: account, layer_key: "anura", enabled: true)
    create(:layer_policy, account: account, layer_key: "voice", enabled: false)

    expect(described_class.enabled).to contain_exactly(paid)
  end

  it "defaults to enabled and not promoted to a hard stop" do
    policy = create(:layer_policy, account: account, layer_key: "blacklist_alliance")

    expect(policy.enabled).to be(true)
    expect(policy.treat_as_hard_stop).to be(false)
  end

  it "lets a buyer promote a soft signal to a hard stop without a deploy" do
    policy = create(:layer_policy, account: account, layer_key: "blacklist_alliance",
                                   treat_as_hard_stop: true, weight_overrides: { "suspected" => -60 })

    expect(policy.reload.treat_as_hard_stop).to be(true)
    expect(policy.weight_overrides).to eq("suspected" => -60)
  end
end
