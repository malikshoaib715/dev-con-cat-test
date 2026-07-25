# frozen_string_literal: true

module Audit
  # The frozen event taxonomy. Queries, dashboards, and the live panel all key
  # off these exact strings, so they are constants — never inline literals.
  # Shape: object.verb, verb in the past tense.
  module Events
    PIXEL_VISIT_RECORDED = "pixel.visit_recorded"
    LEAD_RECEIVED        = "lead.received"
    LEAD_REPLAY_DETECTED = "lead.replay_detected"
    LEAD_ON_HOLD         = "lead.on_hold"

    VERIFICATION_STARTED = "verification.started"
    LAYER_STARTED        = "layer.started"
    LAYER_COMPLETED      = "layer.completed"
    LAYER_SKIPPED        = "layer.skipped"
    LAYER_ERRORED        = "layer.errored"

    CONSENSUS_EVALUATED  = "consensus.evaluated"
    VERDICT_ISSUED       = "verdict.issued"
    CERTIFICATE_ISSUED   = "certificate.issued"

    CREDITS_GRANTED      = "credits.granted"
    CREDITS_RESERVED     = "credits.reserved"
    CREDITS_SETTLED      = "credits.settled"
    CREDITS_ADJUSTED     = "credits.adjusted"
    CREDITS_INSUFFICIENT = "credits.insufficient"

    AUTH_LOGIN_SUCCEEDED = "auth.login_succeeded"
    AUTH_LOGIN_FAILED    = "auth.login_failed"
    AUTH_LOGOUT          = "auth.logout"

    PIXEL_CREATED        = "pixel.created"
    PIXEL_UPDATED        = "pixel.updated"
    POLICY_UPDATED       = "policy.updated"

    ACCOUNT_FLAGGED_LOW_CREDITS = "account.flagged_low_credits"

    API_REQUEST_REJECTED = "api.request_rejected"
    API_THROTTLED        = "api.throttled"
    SYSTEM_ENQUEUE_FAILED = "system.enqueue_failed"

    ALL = [
      PIXEL_VISIT_RECORDED, LEAD_RECEIVED, LEAD_REPLAY_DETECTED, LEAD_ON_HOLD,
      VERIFICATION_STARTED, LAYER_STARTED, LAYER_COMPLETED, LAYER_SKIPPED, LAYER_ERRORED,
      CONSENSUS_EVALUATED, VERDICT_ISSUED, CERTIFICATE_ISSUED,
      CREDITS_GRANTED, CREDITS_RESERVED, CREDITS_SETTLED, CREDITS_ADJUSTED, CREDITS_INSUFFICIENT,
      AUTH_LOGIN_SUCCEEDED, AUTH_LOGIN_FAILED, AUTH_LOGOUT,
      PIXEL_CREATED, PIXEL_UPDATED, POLICY_UPDATED,
      ACCOUNT_FLAGGED_LOW_CREDITS,
      API_REQUEST_REJECTED, API_THROTTLED, SYSTEM_ENQUEUE_FAILED
    ].freeze
  end
end
