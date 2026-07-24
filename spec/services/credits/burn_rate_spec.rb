require "rails_helper"

RSpec.describe Credits::BurnRate do
  let(:account) { create(:account, credit_balance: 700, settings: { "avg_daily_burn" => 250 }) }

  def spend(amount, at: Time.current)
    as_tenant(account) do
      account.credit_ledger_entries.create!(entry_type: "reservation", amount: -amount,
                                           balance_after: account.credit_balance, created_at: at)
    end
  end

  def runway
    as_tenant(account) { described_class.call(account: account) }
  end

  it "measures the week's spending from the ledger" do
    spend(70)
    spend(70, at: 3.days.ago)

    expect(runway.daily_burn).to eq(20.0)
    expect(runway.days_to_zero).to eq(35.0)
  end

  it "counts a refund back against the week's spending" do
    spend(70)
    as_tenant(account) do
      account.credit_ledger_entries.create!(entry_type: "settlement_refund", amount: 35,
                                           balance_after: account.credit_balance)
    end

    expect(runway.daily_burn).to eq(5.0)
  end

  it "ignores movement older than the window" do
    spend(70)
    spend(7_000, at: 8.days.ago)

    expect(runway.daily_burn).to eq(10.0)
  end

  it "ignores grants and adjustments, which are not spending" do
    spend(70)
    as_tenant(account) do
      account.credit_ledger_entries.create!(entry_type: "grant", amount: 5_000,
                                           balance_after: account.credit_balance)
    end

    expect(runway.daily_burn).to eq(10.0)
  end

  # A fresh account has no week to measure. Reporting infinite runway for one that
  # has simply not spent yet would tell the dashboard the opposite of the truth.
  it "falls back to the burn the account was sold on when it has no history" do
    expect(runway.daily_burn).to eq(250.0)
    expect(runway.days_to_zero).to eq(2.8)
  end

  it "reads a seeded burn stored as a string" do
    account.update!(settings: { "avg_daily_burn" => "250" })

    expect(runway.daily_burn).to eq(250.0)
  end

  # This runs inside settlement, inside every finalization: a corrupt value must
  # read as "no seeded burn", never crash the account's every run.
  it "treats a corrupt seeded burn as no burn at all" do
    account.update!(settings: { "avg_daily_burn" => { "oops" => true } })

    expect(runway.daily_burn).to eq(0.0)
    expect(runway.days_to_zero).to eq(Float::INFINITY)
  end

  it "reports an endless runway rather than dividing by zero" do
    account.update!(settings: {})

    expect(runway.daily_burn).to eq(0.0)
    expect(runway.days_to_zero).to eq(Float::INFINITY)
  end

  it "treats a week of net refunds as no burn at all" do
    as_tenant(account) do
      account.credit_ledger_entries.create!(entry_type: "settlement_refund", amount: 40,
                                           balance_after: account.credit_balance)
    end

    expect(runway.days_to_zero).to eq(Float::INFINITY)
  end
end
