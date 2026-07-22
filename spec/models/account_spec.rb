require "rails_helper"

RSpec.describe Account do
  it "assigns a Stripe-style external identifier on create" do
    account = create(:account, public_id: nil)

    expect(account.public_id).to start_with("acct_")
  end

  it "rejects a plan outside the known set" do
    account = build(:account, plan: "platinum")

    expect(account).not_to be_valid
    expect(account.errors[:plan]).to be_present
  end

  it "refuses a negative balance at the database level even if validations are bypassed" do
    account = create(:account, credit_balance: 10)

    expect { account.update_column(:credit_balance, -1) }
      .to raise_error(ActiveRecord::StatementInvalid, /accounts_credit_balance_non_negative/)
  end

  it "reports how much of the cycle allowance has been consumed" do
    account = create(:account, monthly_credit_allowance: 1_000, credit_balance: 250)

    expect(account.allowance_used).to eq(750)
    expect(account.allowance_used_percent).to eq(75)
  end
end
