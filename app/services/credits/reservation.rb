# frozen_string_literal: true

module Credits
  # Funds a verification run up front, before any layer work is dispatched.
  #
  # Reserving rather than billing on completion is what makes "what happens when
  # an account hits zero mid-verification?" unanswerable by construction: a run
  # that was funded at the start cannot run out halfway, and an account that
  # cannot afford one never starts it. The ledger entry is the record; the
  # account's balance is a cached projection of it.
  class Reservation < ApplicationService
    def initialize(account:, run:, layer_keys:)
      @account = account
      @run = run
      @layer_keys = layer_keys
    end

    def call
      require_enclosing_transaction

      # Locked before the balance is read, so a concurrent submission cannot
      # spend the same credits between the check and the deduction. The account
      # row is always the first lock taken, which is what keeps lock ordering
      # consistent across the codebase.
      @account.lock!

      return insufficient if @account.credit_balance < total

      reserve
      success(total)
    end

    private

    # Programmer misuse, not a domain outcome: a reservation that commits
    # separately from the lead and run it funds could leave an account debited for
    # a run that never existed.
    def require_enclosing_transaction
      return if ApplicationRecord.connection.transaction_open?

      raise ArgumentError, "Credits::Reservation must be called inside a transaction"
    end

    def reserve
      @account.update!(credit_balance: @account.credit_balance - total)
      @account.credit_ledger_entries.create!(
        entry_type: "reservation",
        amount: -total,
        balance_after: @account.credit_balance,
        breakdown: costs,
        verification_run: @run,
        memo: "reservation for #{lead.public_id}"
      )
      @run.update!(reserved_credits: total)

      Audit::Recorder.record!(
        Audit::Events::CREDITS_RESERVED,
        subject: lead,
        payload: { total: total, breakdown: costs, balance_after: @account.credit_balance }
      )
    end

    def insufficient
      Audit::Recorder.record!(
        Audit::Events::CREDITS_INSUFFICIENT,
        subject: lead,
        payload: { required: total, available: @account.credit_balance }
      )

      failure("Insufficient credits: this verification costs #{total} and the balance is #{@account.credit_balance}.",
              code: :insufficient_credits)
    end

    def total
      @total ||= costs.values.sum
    end

    # Priced from layer_definitions rather than a constant, so a buyer's per-layer
    # costs are data. An unpriced layer is a bug in the registry or the seeds, not
    # a free check.
    def costs
      @costs ||= LayerDefinition.where(key: @layer_keys).pluck(:key, :cost_credits).to_h.tap do |priced|
        unpriced = @layer_keys - priced.keys
        raise ArgumentError, "no layer_definition for: #{unpriced.join(', ')}" if unpriced.any?
      end
    end

    def lead
      @lead ||= @run.lead
    end
  end
end
