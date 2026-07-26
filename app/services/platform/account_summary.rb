# frozen_string_literal: true

module Platform
  # One account as the platform console reads it: what it holds, how fast it is
  # spending, and whether an operator should be looking at it today.
  #
  # The flags are the whole point of the table — an account that cannot pay and an
  # account about to run dry both need somebody to act before their buyer's leads
  # start being held.
  class AccountSummary
    PAST_DUE = "past due"
    LOW_CREDIT = "low credit"

    Summary = Data.define(:account, :daily_burn, :days_to_zero, :flags) do
      def flagged?
        flags.any?
      end
    end

    def self.call(account:)
      new(account: account).call
    end

    def initialize(account:)
      @account = account
    end

    def call
      Summary.new(account: @account, daily_burn: runway.daily_burn,
                  days_to_zero: runway.days_to_zero, flags: flags)
    end

    private

    # The ledger this reads is tenant-owned, so the tenant is opened explicitly
    # rather than the console being allowed to read across accounts by default.
    def runway
      @runway ||= ActsAsTenant.with_tenant(@account) { Credits::BurnRate.call(account: @account) }
    end

    def flags
      [
        (PAST_DUE if @account.past_due?),
        (LOW_CREDIT if runway.days_to_zero < Account::LOW_CREDIT_DAYS_TO_ZERO)
      ].compact
    end
  end
end
