require "rails_helper"

RSpec.describe Credits::BurnRate do
  # No seeded figure by default: these examples are about what the ledger says.
  # The account's own stated burn gets its own section below.
  let(:account) { create(:account, credit_balance: 700, settings: {}) }

  def spend(amount, at: Time.current)
    as_tenant(account) do
      account.credit_ledger_entries.create!(entry_type: "reservation", amount: -amount,
                                           balance_after: account.credit_balance, created_at: at)
    end
  end

  def runway
    as_tenant(account) { described_class.call(account: account) }
  end

  # Spending older than the window is what makes the window a measurement rather
  # than a first impression, so these examples establish some.
  before { spend(0, at: 30.days.ago) }

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

  describe "the burn the account was sold on" do
    before { account.update!(settings: { "avg_daily_burn" => 250 }) }

    # A fresh account has no week to measure. Reporting infinite runway for one
    # that has simply not spent yet would tell the dashboard the opposite of the
    # truth.
    it "stands in when the account has no spending at all" do
      as_tenant(account) { CreditLedgerEntry.delete_all }

      expect(runway.daily_burn).to eq(250.0)
      expect(runway.days_to_zero).to eq(2.8)
    end

    # The seeded world in miniature: an account whose whole history is a few
    # minutes old, spending far below the rate it actually runs at.
    it "wins over a window the ledger has not filled yet" do
      as_tenant(account) { CreditLedgerEntry.delete_all }
      spend(70)

      expect(runway.daily_burn).to eq(250.0)
    end

    it "gives way once the ledger covers a whole week" do
      spend(7_000)

      expect(runway.daily_burn).to eq(1_000.0)
    end

    it "is read even when stored as a string" do
      as_tenant(account) { CreditLedgerEntry.delete_all }
      account.update!(settings: { "avg_daily_burn" => "250" })

      expect(runway.daily_burn).to eq(250.0)
    end
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
