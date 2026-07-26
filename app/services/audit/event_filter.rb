# frozen_string_literal: true

module Audit
  # What the audit explorers may be asked, and how each question narrows the
  # spine. Both explorers — the account's and the platform's — ask it here, so the
  # two cannot drift into accepting different things.
  #
  # Every filter maps onto one of the indexes the table was built with (§6). A
  # value outside the frozen taxonomy, the closed actor set or the closed subject
  # set is dropped rather than queried for: a hand-edited URL is a bad question,
  # not a server error, and never a way to ask an unindexed one.
  class EventFilter
    Filters = Data.define(:event_type, :actor_type, :session_id, :subject, :account_id, :from, :to)

    def initialize(params)
      @params = params
    end

    def filters
      @filters ||= Filters.new(
        event_type: @params[:event_type].presence_in(Events::ALL),
        actor_type: @params[:actor_type].presence_in(AuditEvent::ACTOR_TYPES),
        session_id: @params[:session_id].presence,
        subject: subject,
        account_id: @params[:account_id].presence,
        from: timestamp(@params[:from]),
        # A reader asking for events up to the 3rd means the whole of the 3rd.
        to: timestamp(@params[:to])&.end_of_day
      )
    end

    def apply(events)
      events = events.of_type(filters.event_type)        if filters.event_type
      events = events.for_actor_type(filters.actor_type) if filters.actor_type
      events = events.for_session(filters.session_id)    if filters.session_id
      events = events.about(*filters.subject)            if filters.subject
      events = events.for_account(filters.account_id)    if filters.account_id
      events = events.occurred_from(filters.from)        if filters.from
      events = events.occurred_to(filters.to)            if filters.to
      events
    end

    private

    # Arrives as a pair from a link — a lead timeline offering "everything about
    # this record". Only meaningful together, so only accepted together.
    def subject
      subject_type = @params[:subject_type].presence_in(AuditEvent::SUBJECT_TYPES)
      return nil if subject_type.nil? || @params[:subject_id].blank?

      [ subject_type, @params[:subject_id] ]
    end

    def timestamp(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, RangeError
      nil
    end
  end
end
