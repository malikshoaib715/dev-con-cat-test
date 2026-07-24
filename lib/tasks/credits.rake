# frozen_string_literal: true

namespace :credits do
  desc "Assert every account's balance equals the sum of its ledger"
  task audit: :environment do
    accounts = ActsAsTenant.without_tenant { Account.ordered_by_name.to_a }
    mismatched = accounts.reject { |account| CreditsAudit.report(account) }

    abort "credits:audit FAILED for #{mismatched.map(&:public_id).join(', ')}" if mismatched.any?

    puts "credits:audit OK — #{accounts.size} #{'account'.pluralize(accounts.size)} reconcile"
  end

  # The ledger is the truth and `accounts.credit_balance` is a cached projection of
  # it. This is the operational check that they have not drifted; the same
  # invariant is asserted by spec/services/credits/settlement_spec.rb.
  module CreditsAudit
    def self.report(account)
      ledger = ActsAsTenant.with_tenant(account) { account.credit_ledger_entries.sum(:amount) }
      reconciles = ledger == account.credit_balance

      puts format("  %-22s balance %-8d ledger %-8d %s",
                  account.public_id, account.credit_balance, ledger, reconciles ? "ok" : "MISMATCH")
      reconciles
    end
  end
end
