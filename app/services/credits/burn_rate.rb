# frozen_string_literal: true

module Credits
  # How fast this account is spending, and how long it has left.
  #
  # Measured from the ledger rather than from a stored figure, so it reflects what
  # actually happened this week. A brand-new account has no week to measure, and
  # falls back to the burn its plan was sold on — reporting "infinite runway" for
  # an account that simply has not spent yet would tell the super-admin dashboard
  # the opposite of the truth.
  class BurnRate
    WINDOW = 7.days

    Runway = Data.define(:daily_burn, :days_to_zero)

    def self.call(account:)
      new(account: account).call
    end

    # An account spending nothing never runs out. Said explicitly because the
    # alternative is a division by zero in the one place a dashboard reads.
    def self.days_to_zero(balance:, daily_burn:)
      return Float::INFINITY unless daily_burn.positive?

      balance / daily_burn.to_f
    end

    def initialize(account:)
      @account = account
    end

    def call
      Runway.new(
        daily_burn: daily_burn,
        days_to_zero: self.class.days_to_zero(balance: @account.credit_balance, daily_burn: daily_burn)
      )
    end

    private

    def daily_burn
      return seeded_burn if recent_movements.empty?
      return observed_burn if history_spans_window?

      # A rate needs a window to be a rate. Until the ledger covers one, the
      # figure the plan was sold on stands beside the observed one and the higher
      # wins — this number's job is to warn somebody before an account's leads
      # start being held, and understating the burn is the expensive mistake.
      [ observed_burn, seeded_burn ].max
    end

    def observed_burn
      (-recent_movements.sum / WINDOW.in_days).round(2)
    end

    # Is there spending older than the window, i.e. does the window contain a
    # whole week of this account's behaviour rather than the first hour of it?
    def history_spans_window?
      oldest_spend = @account.credit_ledger_entries.spending.minimum(:created_at)

      oldest_spend.present? && oldest_spend <= WINDOW.ago
    end

    # Reservations are negative and refunds positive, so their sum is the net spend
    # — a run whose layers were half refunded cost this account half as much.
    # Grants and adjustments are not spending and are deliberately excluded.
    def recent_movements
      @recent_movements ||= @account.credit_ledger_entries.spending.since(WINDOW.ago).pluck(:amount)
    end

    # Float(), not to_f: this runs inside settlement, inside every finalization,
    # and settings is jsonb — a corrupt value would otherwise crash every run for
    # the account rather than read as "no seeded burn".
    def seeded_burn
      Float(@account.settings["avg_daily_burn"], exception: false) || 0.0
    end
  end
end
