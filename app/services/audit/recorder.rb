# frozen_string_literal: true

module Audit
  # The only write path into the event spine. Everything the pixel, the engine,
  # and the dashboards do lands here, and the live panel is a rendering of what
  # this writes.
  class Recorder
    def self.record!(event_type, subject: nil, payload: {}, actor: Current.actor, account: nil)
      new(event_type, subject:, payload:, actor:, account:).record!
    end

    def initialize(event_type, subject:, payload:, actor:, account:)
      @event_type = event_type
      @subject = subject
      @payload = payload
      @actor = actor
      @account = account
    end

    def record!
      event = persist
      Realtime::Broadcaster.publish(event)
      event
    rescue StandardError => e
      # Auditing must never take down the business flow in production — but it
      # must never fail silently while we are building either.
      raise if Rails.env.local?

      Rails.logger.error("[audit-drop] #{@event_type}: #{e.class} #{e.message}")
      nil
    end

    private

    # The recorder opens its own tenant rather than trusting the ambient one:
    # audit writes happen from Warden hooks and jobs too, where no tenant has
    # been set yet. Platform-level events (a failed login for an unknown email)
    # have no tenant at all, and acts_as_tenant would otherwise refuse them.
    def persist
      return ActsAsTenant.with_tenant(account) { AuditEvent.create!(attributes) } if account

      ActsAsTenant.without_tenant { AuditEvent.create!(attributes) }
    end

    def attributes
      {
        account_id: account&.id,
        event_type: @event_type,
        subject: @subject,
        payload: @payload,
        actor_type: actor_type,
        actor_id: @actor.try(:id),
        request_id: Current.request_id,
        session_id: Current.session_id,
        ip_address: Current.ip_address,
        occurred_at: Time.current
      }
    end

    def account
      return @resolved_account if defined?(@resolved_account)

      @resolved_account = @account || Current.account || @subject.try(:account)
    end

    def actor_type
      @actor ? @actor.class.name.underscore : "system"
    end
  end
end
