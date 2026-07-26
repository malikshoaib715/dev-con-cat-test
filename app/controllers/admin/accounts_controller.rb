# frozen_string_literal: true

module Admin
  # Read-only, deliberately. An operator can see any buyer's position; changing it
  # — status, balance, plan — is a billing action with consequences for somebody
  # else's money, and is not something a console should offer without the
  # dual-control it would deserve.
  class AccountsController < BaseController
    RECENT_ROW_COUNT = 20

    def index
      authorize Account, :index?

      @summaries = Account.ordered_by_name.map { |account| Platform::AccountSummary.call(account: account) }
    end

    def show
      @account = Account.find_by!(public_id: params[:id])
      authorize @account

      @summary = Platform::AccountSummary.call(account: @account)
      load_account_detail
    end

    private

    # Each read opens the account's own tenant explicitly. Nothing here is
    # ambiently cross-tenant, which is what keeps "the operator can see
    # everything" a list of deliberate reads rather than a default.
    def load_account_detail
      ActsAsTenant.with_tenant(@account) do
        @pixels = @account.pixels.ordered.to_a
        @lead_counts = @account.leads.counts_by_verdict
        @ledger_entries = @account.credit_ledger_entries.recent_first.limit(RECENT_ROW_COUNT).to_a
        @events = @account.audit_events.recent_first.limit(RECENT_ROW_COUNT).includes(:subject).to_a
      end
    end
  end
end
