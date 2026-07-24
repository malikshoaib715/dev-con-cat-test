module Seeds
  module Accounts
    # The cycle allowance is granted through the ledger like any other credit
    # movement, so `balance == sum(ledger)` holds from the very first row.
    # Chunk 3.6 adds the reconciling adjustment that lands each balance on the
    # figure in accounts.json.
    def self.load!
      MockData.read("accounts.json").fetch("accounts").each do |attributes|
        account = upsert_account(attributes)
        grant_monthly_allowance(account)
      end

      puts "  accounts: #{Account.count}"
    end

    def self.upsert_account(attributes)
      account = Account.find_or_initialize_by(public_id: attributes.fetch("account_id"))
      account.update!(
        name: attributes.fetch("company_name"),
        plan: attributes.fetch("plan"),
        status: attributes.fetch("status"),
        monthly_credit_allowance: attributes.fetch("monthly_credit_allowance"),
        cycle_start: attributes.fetch("cycle_start"),
        cycle_end: attributes.fetch("cycle_end"),
        billing_email: attributes.fetch("billing_contact"),
        # The burn Credits::BurnRate falls back to until the account has a week of
        # ledger history to measure. Merged rather than assigned so a buyer's
        # threshold overrides in the same column survive a re-seed.
        settings: account.settings.merge("avg_daily_burn" => attributes.fetch("avg_daily_burn"))
      )
      account
    end

    def self.grant_monthly_allowance(account)
      ActsAsTenant.with_tenant(account) do
        next if account.credit_ledger_entries.entry_type_grant.exists?

        account.with_lock do
          account.update!(credit_balance: account.credit_balance + account.monthly_credit_allowance)
          account.credit_ledger_entries.create!(
            entry_type: "grant",
            amount: account.monthly_credit_allowance,
            balance_after: account.credit_balance,
            memo: "monthly allowance for cycle starting #{account.cycle_start}",
            created_at: Time.current
          )
        end

        Audit::Recorder.record!(
          Audit::Events::CREDITS_GRANTED,
          subject: account,
          account: account,
          payload: { amount: account.monthly_credit_allowance, balance_after: account.credit_balance }
        )
      end
    end
  end
end
