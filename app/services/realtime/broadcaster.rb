# frozen_string_literal: true

module Realtime
  # Maps audit events onto the wire shapes the landing page already consumes, so
  # the live panel and the CRM feed are both just renderings of the event spine.
  #
  # The Action Cable transport lands in chunk 4.1; until then every audit write
  # still passes through here, which is what keeps that change a one-file change.
  class Broadcaster
    def self.publish(event)
      new(event).publish
    end

    def initialize(event)
      @event = event
    end

    def publish
      Rails.logger.debug { "[realtime] #{@event.event_type} subject=#{@event.subject_type}##{@event.subject_id}" }
      nil
    rescue StandardError => e
      # Realtime is best-effort: the database row is the truth and a
      # reconnecting client can always re-read it.
      Rails.logger.error("[realtime-drop] #{@event.event_type}: #{e.class} #{e.message}")
      nil
    end
  end
end
