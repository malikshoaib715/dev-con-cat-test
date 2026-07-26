# frozen_string_literal: true

module Admin
  # What an operator needs to see at a glance: which buyers are in trouble, what
  # the platform is deciding, and what just happened.
  class DashboardController < BaseController
    RECENT_EVENT_COUNT = 20

    def index
      authorize Account, :index?

      # A handful of accounts, each needing its own tenant opened to read its
      # ledger — a query apiece is the honest cost of not reading across tenants
      # by default, and is bounded by the number of buyers on the platform.
      @summaries = Account.ordered_by_name.map { |account| Platform::AccountSummary.call(account: account) }
      @verdict_counts = ConsensusVerdict.counts_by_verdict
      @recent_events = AuditEvent.recent_first.limit(RECENT_EVENT_COUNT).includes(:subject).to_a
      @account_names = Account.pluck(:id, :name).to_h
    end
  end
end
