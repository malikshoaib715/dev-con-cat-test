# frozen_string_literal: true

class Rack::Attack
  # Its own store: throttle counters are not application cache and must not be
  # wiped by an unrelated Rails.cache.clear.
  self.cache.store = ActiveSupport::Cache::MemoryStore.new

  # Brute force is throttled per source and per mailbox: rotating IPs still
  # cannot grind a single account, and one hostile IP cannot grind many.
  throttle("logins/ip", limit: 10, period: 60.seconds) do |request|
    request.ip if LoginAttempt.submission?(request)
  end

  throttle("logins/email", limit: 5, period: 60.seconds) do |request|
    LoginAttempt.submitted_email(request) if LoginAttempt.submission?(request)
  end

  self.throttled_responder = lambda do |request|
    Current.request_id ||= request.env["action_dispatch.request_id"]
    Current.ip_address ||= request.ip
    Audit::Recorder.record!(
      Audit::Events::API_THROTTLED,
      payload: { rule: request.env["rack.attack.matched"], path: request.path }
    )

    retry_after = (request.env["rack.attack.match_data"] || {})[:period].to_i
    [
      429,
      { "Content-Type" => "application/json", "Retry-After" => retry_after.to_s },
      [ { error: { code: "throttled", message: "Too many requests.", request_id: Current.request_id } }.to_json ]
    ]
  end
end

# Counters would otherwise leak between examples; specs that exercise throttling
# enable it and clear the store themselves.
Rack::Attack.enabled = !Rails.env.test?
