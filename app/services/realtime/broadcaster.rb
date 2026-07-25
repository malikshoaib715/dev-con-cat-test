# frozen_string_literal: true

module Realtime
  # Pushes audit events to the live panel as they are written.
  #
  # This is the whole of "real time": there is no separate event source and no
  # parallel bookkeeping. Audit::Recorder writes a row and hands it here, which is
  # why the panel can never show something the audit trail does not have — it is
  # literally a rendering of the spine.
  #
  # Two consumers read the same write: the visitor's live panel and the buyer's
  # CRM table. Deciding what each of them makes of an event is their own job; this
  # class only fans out and guarantees the contract below.
  #
  # Best-effort by design. A broadcast that fails is logged and swallowed: the
  # database row is the truth and a client that missed a frame re-reads it through
  # the polling fallback. Nothing in the verification pipeline is allowed to fail
  # because a socket did — and one consumer failing must not cost the other its
  # frame, which is why each is delivered inside its own rescue.
  class Broadcaster
    CONSUMERS = [ PanelBroadcast, CrmBroadcast ].freeze

    def self.publish(event)
      new(event).publish
    end

    def initialize(event)
      @event = event
    end

    def publish
      return nil if lead.nil?

      CONSUMERS.each { |consumer| deliver(consumer) }
      nil
    end

    private

    def deliver(consumer)
      consumer.call(event: @event, lead: lead)
    rescue StandardError => e
      Rails.logger.error("[realtime-drop] #{@event.event_type}: #{e.class} #{e.message}")
      nil
    end

    # Every frame either consumer sends belongs to one lead's verification. Events
    # about anything else — a login, a pixel edit, an account flagged for low
    # credits — have nowhere to arrive.
    #
    # The recorder has just built this event with the lead in hand, so the
    # association is already loaded and reading it costs no query.
    def lead
      return nil unless @event.subject_type == "Lead"

      @event.subject
    end
  end
end
