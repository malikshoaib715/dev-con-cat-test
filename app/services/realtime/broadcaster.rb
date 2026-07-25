# frozen_string_literal: true

module Realtime
  # Pushes audit events to the live panel as they are written.
  #
  # This is the whole of "real time": there is no separate event source and no
  # parallel bookkeeping. Audit::Recorder writes a row and hands it here, which is
  # why the panel can never show something the audit trail does not have — it is
  # literally a rendering of the spine.
  #
  # Best-effort by design. A broadcast that fails is logged and swallowed: the
  # database row is the truth and a client that missed a frame re-reads it through
  # the polling fallback. Nothing in the verification pipeline is allowed to fail
  # because a socket did.
  class Broadcaster
    def self.publish(event)
      new(event).publish
    end

    def initialize(event)
      @event = event
    end

    def publish
      return nil if lead.nil?

      frame = PanelFrame.for(@event)
      return nil if frame.nil?

      ActionCable.server.broadcast(PanelFrame.stream_name(lead.public_id), frame)
    rescue StandardError => e
      Rails.logger.error("[realtime-drop] #{@event.event_type}: #{e.class} #{e.message}")
      nil
    end

    private

    # Every panel frame belongs to one lead's verification. Events about anything
    # else — a login, a pixel edit, an account flagged for low credits — have no
    # panel to reach.
    #
    # The recorder has just built this event with the lead in hand, so the
    # association is already loaded and reading it costs no query.
    def lead
      return nil unless @event.subject_type == "Lead"

      @event.subject
    end
  end
end
