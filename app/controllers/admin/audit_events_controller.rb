# frozen_string_literal: true

module Admin
  # The same explorer as the account's, across every tenant and with one more
  # question to ask: whose event was it. Platform-wide queries hit the
  # (event_type, occurred_at) index rather than the account-prefixed ones.
  class AuditEventsController < BaseController
    include Pagy::Backend

    def index
      authorize AuditEvent, :index?

      events = policy_scope(AuditEvent).recent_first.includes(:subject)
      @pagy, @events = pagy(filter.apply(events))
      # Names for the account column: the events span tenants, so the association
      # cannot be preloaded through a single scope.
      @account_names = Account.pluck(:id, :name).to_h
      @accounts = Account.ordered_by_name.to_a
    end

    private

    def filter
      @filter ||= Audit::EventFilter.new(params)
    end

    def filters
      filter.filters
    end
    helper_method :filters
  end
end
