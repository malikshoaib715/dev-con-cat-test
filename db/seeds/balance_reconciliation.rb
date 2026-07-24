module Seeds
  # Lands each account on the balance in accounts.json without inventing money.
  #
  # The fixture states a cycle's worth of prior usage that has no ledger behind it,
  # and the twelve seeded runs then spend through the real reserve-and-settle path.
  # Rather than back-filling thousands of imaginary verifications, the difference is
  # recorded as one aggregate adjustment — so the demo opens on the fixtures' own
  # numbers and `balance == sum(ledger)` still holds.
  #
  # Runs last, and computes the difference rather than assuming it, which makes it
  # order-proof and idempotent: a re-seed finds nothing to reconcile.
  module BalanceReconciliation
    MEMO = "prior cycle usage (aggregate)"

    def self.load!
      MockData.read("accounts.json").fetch("accounts").each do |attributes|
        account = Account.find_by!(public_id: attributes.fetch("account_id"))
        reconcile(account, attributes.fetch("credits_remaining"))
      end

      puts "  balances reconciled to accounts.json"
    end

    def self.reconcile(account, target_balance)
      ActsAsTenant.with_tenant(account) do
        delta = target_balance - account.credit_balance
        next if delta.zero?

        adjust(account, target_balance, delta)
      end
    end

    def self.adjust(account, target_balance, delta)
      account.with_lock do
        account.update!(credit_balance: target_balance)
        account.credit_ledger_entries.create!(
          entry_type: "adjustment",
          amount: delta,
          balance_after: target_balance,
          memo: MEMO,
          created_at: Time.current
        )
      end

      Audit::Recorder.record!(
        Audit::Events::CREDITS_ADJUSTED,
        subject: account,
        account: account,
        payload: { amount: delta, balance_after: target_balance, memo: MEMO }
      )
    end
  end
end
