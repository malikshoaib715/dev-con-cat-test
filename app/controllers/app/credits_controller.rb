# frozen_string_literal: true

module App
  # What the account has, what it is spending, and every movement that got it
  # there. Read-only by design: credits move through the pipeline, never through
  # a form.
  class CreditsController < BaseController
    include Pagy::Backend

    def show
      # A singular resource, so the question is the list question — may this user
      # see their account's ledger at all.
      authorize CreditLedgerEntry, :index?

      @runway = Credits::BurnRate.call(account: current_account)
      @pagy, @entries = pagy(ledger_entries)
    end

    private

    # The run and its lead come along: the ledger's whole readability rests on
    # being able to say which lead each movement was for, and asking a row at a
    # time is the N+1 this page exists to avoid.
    def ledger_entries
      policy_scope(current_account.credit_ledger_entries)
        .recent_first
        .includes(verification_run: :lead)
    end
  end
end
