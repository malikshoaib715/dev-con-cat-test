require "rails_helper"

RSpec.describe CreditLedgerEntry do
  let(:account) { create(:account) }

  before { ActsAsTenant.current_tenant = account }

  it "is append-only" do
    entry = create(:credit_ledger_entry, account: account)

    expect { entry.update!(amount: 999) }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "allows only one entry of each type per run, so a retried finaliser cannot double-refund" do
    run = create(:verification_run, account: account)
    create(:credit_ledger_entry, account: account, verification_run: run, entry_type: "reservation", amount: -17)

    expect {
      create(:credit_ledger_entry, account: account, verification_run: run, entry_type: "reservation", amount: -17)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "still allows a refund alongside the reservation it settles" do
    run = create(:verification_run, account: account)
    create(:credit_ledger_entry, account: account, verification_run: run, entry_type: "reservation", amount: -17)

    refund = create(:credit_ledger_entry, account: account, verification_run: run,
                                          entry_type: "settlement_refund", amount: 5)

    expect(refund).to be_persisted
  end

  it "does not constrain account-level entries that belong to no run" do
    create(:credit_ledger_entry, account: account, verification_run: nil, entry_type: "grant")
    second = create(:credit_ledger_entry, account: account, verification_run: nil, entry_type: "grant")

    expect(second).to be_persisted
  end
end
