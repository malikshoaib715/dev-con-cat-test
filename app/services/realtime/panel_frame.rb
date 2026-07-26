# frozen_string_literal: true

module Realtime
  # The wire vocabulary of the live panel, in one place.
  #
  # Both transports read from here — the Action Cable broadcaster and the polling
  # fallback — so a page that loses its socket and starts polling keeps receiving
  # exactly the same frames. Two hand-written mappings would drift the first time
  # a payload key changed, and the fallback is precisely the path nobody exercises
  # by hand.
  #
  # The shapes are the ones the landing page already consumes, unchanged:
  #   { type: "layer_result", layer:, verdict: pass|warn|fail|skip, detail: }
  #   { type: "final_verdict", verdict: "ACCEPT", score: 0.0..1.0, reasons: [] }
  #   { type: "info", message: }
  module PanelFrame
    module_function

    # One stream per lead, named by the public id the token carries — never by the
    # client-supplied session id, which is guessable.
    def stream_name(lead_public_id)
      "verification:#{lead_public_id}"
    end

    # Returns the frame for an audit event, or nil when the event is not something
    # the panel renders. Most of the spine isn't: the panel is a view of the
    # verification, not of every write.
    #
    # Every frame carries its event's id, on the socket exactly as in the polling
    # response. The id is what lets the pixel deduplicate: frames broadcast before
    # the page's subscription was confirmed are re-fetched in a catch-up read, and
    # a socket that fell back to polling re-reads history — both would paint rows
    # twice if the two transports' frames could not be recognised as the same one.
    def for(event)
      payload = event.payload.with_indifferent_access
      frame =
        case event.event_type
        when Audit::Events::LAYER_COMPLETED, Audit::Events::LAYER_SKIPPED then layer_result(payload)
        when Audit::Events::LAYER_ERRORED     then errored_layer_result(payload)
        when Audit::Events::VERDICT_ISSUED    then final_verdict(payload)
        when Audit::Events::CREDITS_RESERVED  then info("credits reserved (#{payload[:total]})")
        when Audit::Events::CREDITS_SETTLED   then info("credits settled — #{payload[:refunded]} refunded")
        when Audit::Events::CERTIFICATE_ISSUED then info("certificate #{payload[:certificate_id]} issued")
        end

      frame&.merge(id: event.id)
    end

    def layer_result(payload)
      { type: "layer_result", layer: payload[:layer_key], verdict: payload[:panel_verdict],
        detail: payload[:detail] }
    end

    # An errored layer carries the exception, not panel fields — the vendor never
    # answered. It shows as a warning rather than a failure: an unavailable check
    # is not a failed check, and whether it costs the lead its verdict is the
    # consensus engine's decision, per the layer's criticality (§7.5).
    def errored_layer_result(payload)
      { type: "layer_result", layer: payload[:layer_key], verdict: "warn", detail: "layer unavailable" }
    end

    # The page compares the verdict with `=== "ACCEPT"` and multiplies the score by
    # 100, so it is upcased and expressed as a fraction here rather than the page
    # being changed to meet us.
    def final_verdict(payload)
      { type: "final_verdict", verdict: payload[:verdict].to_s.upcase,
        score: payload[:score].to_f / 100, reasons: payload[:reasons] }
    end

    def info(message)
      { type: "info", message: message }
    end
  end
end
