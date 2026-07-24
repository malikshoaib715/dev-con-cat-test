# frozen_string_literal: true

module Credits
  # Gives back what the run did not spend.
  #
  # The lead was funded up front, so nothing here can leave an account overdrawn:
  # this only ever returns credits. A layer that had nothing to judge and a layer
  # that could not answer are both refunded — a buyer pays for checks that ran,
  # not for checks that were attempted.
  #
  # Prices come from the reservation's own breakdown rather than from
  # `layer_definitions`, deliberately: what was charged is a historical fact, and
  # repricing at settlement time would let a cost change mid-flight refund more
  # than was ever taken.
  class Settlement < ApplicationService
    REFUNDABLE_STATUSES = %w[not_applicable errored].freeze

    def initialize(run:)
      @run = run
    end

    def call
      return success(0) if already_settled?

      refunded = 0
      ApplicationRecord.transaction do
        # Same lock ordering as Credits::Reservation: the account row first, every
        # time, so two movements on one account can never deadlock each other.
        account.lock!
        refunded = settle
      end

      success(refunded)
    rescue ActiveRecord::RecordNotUnique
      # Another delivery of the finalizer settled this run between the check above
      # and the insert. The unique index on (verification_run_id, entry_type) is
      # what makes that harmless rather than a double refund.
      success(0)
    end

    private

    def settle
      refunded = refunds.values.sum

      account.update!(credit_balance: account.credit_balance + refunded)
      record_entry(refunded)
      @run.update!(settled_credits: @run.reserved_credits - refunded)
      record_audit(refunded)
      flag_low_credits(refunded)

      refunded
    end

    # Written even when there is nothing to give back. A zero-amount entry is this
    # run's "settled" marker, which is what makes the retry contract the same
    # whether or not anything was refundable.
    def record_entry(refunded)
      account.credit_ledger_entries.create!(
        entry_type: "settlement_refund",
        amount: refunded,
        balance_after: account.credit_balance,
        breakdown: refunds,
        verification_run: @run,
        memo: "settlement for #{lead.public_id}"
      )
    end

    def record_audit(refunded)
      Audit::Recorder.record!(
        Audit::Events::CREDITS_SETTLED,
        subject: lead,
        account: account,
        payload: { refunded: refunded, breakdown: refunds, spent: @run.reserved_credits - refunded,
                   balance_after: account.credit_balance }
      )
    end

    # The dashboard's low-credit warning gets a queryable trail rather than being
    # recomputed from nowhere. The comparison is across the whole run — what the
    # account had before it spent on this lead against what it has now — because a
    # refund on its own can only ever improve the runway.
    def flag_low_credits(refunded)
      runway = BurnRate.call(account: account)
      return unless runway.days_to_zero < Account::LOW_CREDIT_DAYS_TO_ZERO

      spent = @run.reserved_credits - refunded
      before = BurnRate.days_to_zero(balance: account.credit_balance + spent, daily_burn: runway.daily_burn)
      return if before < Account::LOW_CREDIT_DAYS_TO_ZERO

      Audit::Recorder.record!(
        Audit::Events::ACCOUNT_FLAGGED_LOW_CREDITS,
        subject: account,
        account: account,
        payload: { balance: account.credit_balance, daily_burn: runway.daily_burn,
                   days_to_zero: runway.days_to_zero.round(2) }
      )
    end

    def refunds
      @refunds ||= @run.layer_results.where(status: REFUNDABLE_STATUSES).pluck(:layer_key)
                       .index_with { |layer_key| reserved_costs.fetch(layer_key, 0) }
                       .select { |_layer_key, cost| cost.positive? }
    end

    # A layer the account never bought was never charged for, so it is absent here
    # and refunds nothing.
    def reserved_costs
      @reserved_costs ||= @run.credit_ledger_entries.entry_type_reservation.first&.breakdown || {}
    end

    def already_settled?
      @run.credit_ledger_entries.entry_type_settlement_refund.exists?
    end

    def account
      @account ||= @run.account
    end

    def lead
      @lead ||= @run.lead
    end
  end
end
