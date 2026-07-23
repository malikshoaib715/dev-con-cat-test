# frozen_string_literal: true

module Layers
  # Is the visitor hiding where they are, and did they browse from one place and
  # submit from another? The second question is the one a single IP lookup cannot
  # answer, and it is why the pixel fires a visit beacon before the form is ever
  # filled in.
  class VpnProxyProcessor < BaseProcessor
    ANONYMIZERS = {
      "is_vpn" => "VPN",
      "is_proxy" => "proxy",
      "is_tor" => "Tor exit node",
      "is_datacenter" => "datacenter IP"
    }.freeze

    ELEVATED_RISK = "medium"

    def call
      return anonymizing_network if anonymizers_detected.any?
      return elevated_risk if payload["risk"] == ELEVATED_RISK

      completed(verdict: "clean", panel_verdict: "pass", detail: "residential IP, submit matches visit")
    end

    private

    def anonymizing_network
      completed(
        verdict: "anonymizing_network",
        panel_verdict: "fail",
        detail: [ "#{anonymizers_detected.to_sentence} detected", mismatch_detail ].compact.join("; "),
        signals: [ "anonymizing_network", visit_ip_mismatch? ? "visit_ip_mismatch" : nil ].compact
      )
    end

    # A clean IP the vendor is still uneasy about — worth a human's attention, not
    # worth much of the score.
    def elevated_risk
      completed(
        verdict: "risk_medium",
        panel_verdict: "warn",
        detail: "residential IP, elevated risk",
        signals: [ "risk_medium" ]
      )
    end

    def anonymizers_detected
      @anonymizers_detected ||= ANONYMIZERS.filter_map { |field, label| label if payload[field] }
    end

    # Browsing from a residential address and submitting through a VPN is the
    # masking pattern; on its own the VPN is weaker evidence.
    def visit_ip_mismatch?
      payload["site_visit_ip_matches_submit_ip"] == false
    end

    def mismatch_detail
      "visit IP ≠ submit IP" if visit_ip_mismatch?
    end
  end
end
