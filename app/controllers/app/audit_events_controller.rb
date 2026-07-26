# frozen_string_literal: true

module App
  # The account's own view of the event spine. Every filter here maps onto one of
  # the indexes the table was built with (§6) — which is the answer to "why these
  # filters and not others": a filter the indexes cannot serve is a table scan
  # waiting to happen.
  #
  # Read-only, because the spine is append-only. There are no other actions to add.
  class AuditEventsController < BaseController
    include Pagy::Backend

    def index
      @pagy, @events = pagy(filtered_events)
    end

    private

    def filtered_events
      events = policy_scope(current_account.audit_events).recent_first.includes(:subject)
      events = events.of_type(filters[:event_type])          if filters[:event_type]
      events = events.for_session(filters[:session_id])       if filters[:session_id]
      events = events.for_actor_type(filters[:actor_type])    if filters[:actor_type]
      events = events.about(*filters[:subject])               if filters[:subject]
      events = events.occurred_from(filters[:from])           if filters[:from]
      events = events.occurred_to(filters[:to])               if filters[:to]
      events
    end

    def filters
      @filters ||= {
        event_type: params[:event_type].presence_in(Audit::Events::ALL),
        actor_type: params[:actor_type].presence_in(AuditEvent::ACTOR_TYPES),
        session_id: params[:session_id].presence,
        subject: subject_filter,
        from: timestamp(params[:from]),
        to: timestamp(params[:to])&.end_of_day
      }
    end
    helper_method :filters

    # Carried through the filter form so narrowing by date does not silently widen
    # the query back out to the whole account.
    def subject_filter_params
      return {} if filters[:subject].nil?

      { subject_type: filters[:subject].first, subject_id: filters[:subject].last }
    end
    helper_method :subject_filter_params

    # Arrives as a pair from a link — a lead's timeline offering "everything about
    # this record". Only meaningful together, so only accepted together.
    def subject_filter
      subject_type = params[:subject_type].presence_in(AuditEvent::SUBJECT_TYPES)
      return nil if subject_type.nil? || params[:subject_id].blank?

      [ subject_type, params[:subject_id] ]
    end

    def timestamp(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, RangeError
      nil
    end
  end
end
