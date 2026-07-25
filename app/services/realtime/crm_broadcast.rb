# frozen_string_literal: true

module Realtime
  # The buyer's CRM table, kept current off the same audit write that feeds the
  # pixel panel. A lead appears the moment it is captured and its row is rewritten
  # the moment it is decided, without anybody refreshing.
  #
  # A filtered CRM will accept a prepended row that does not match its filters —
  # the price of a stream that does not know what the reader asked for. The row is
  # correct, and the next load re-applies the filter.
  class CrmBroadcast
    TARGET = "leads"
    PARTIAL = "app/leads/lead"

    # One stream per account, addressed by public id. turbo-rails signs the name
    # into the page, so nobody can subscribe to a feed by guessing it.
    def self.stream_name(account)
      "account_#{account.public_id}_leads"
    end

    def self.call(event:, lead:)
      new(event: event, lead: lead).call
    end

    def initialize(event:, lead:)
      @event = event
      @lead = lead
    end

    def call
      case @event.event_type
      when Audit::Events::LEAD_RECEIVED  then prepend_row
      when Audit::Events::VERDICT_ISSUED then replace_row
      end
    end

    private

    def prepend_row
      Turbo::StreamsChannel.broadcast_prepend_to(stream_name, target: TARGET, partial: PARTIAL, locals: locals)
    end

    def replace_row
      Turbo::StreamsChannel.broadcast_replace_to(stream_name, target: dom_id, partial: PARTIAL, locals: locals)
    end

    def stream_name
      self.class.stream_name(@lead.account)
    end

    def dom_id
      ActionView::RecordIdentifier.dom_id(@lead)
    end

    def locals
      { lead: @lead }
    end
  end
end
