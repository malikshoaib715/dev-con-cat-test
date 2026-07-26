# frozen_string_literal: true

module App
  # The account's own view of the event spine. Which questions may be asked, and
  # how each narrows the query, is Audit::EventFilter's business — this controller
  # only decides whose events are in scope.
  #
  # Read-only, because the spine is append-only. There are no other actions to add.
  class AuditEventsController < BaseController
    include Pagy::Backend

    def index
      events = policy_scope(current_account.audit_events).recent_first.includes(:subject)
      @pagy, @events = pagy(filter.apply(events))
    end

    private

    def filter
      @filter ||= Audit::EventFilter.new(params)
    end

    def filters
      filter.filters
    end
    helper_method :filters

    # Carried through the filter form so narrowing by date does not silently widen
    # the query back out to the whole account.
    def subject_filter_params
      return {} if filters.subject.nil?

      { subject_type: filters.subject.first, subject_id: filters.subject.last }
    end
    helper_method :subject_filter_params
  end
end
