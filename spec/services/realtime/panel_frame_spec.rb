require "rails_helper"

RSpec.describe Realtime::PanelFrame do
  # Unsaved and untenanted on purpose: the mapping is a pure function of the
  # event, and an in-memory payload keeps the symbol keys that a reloaded row
  # hands back as strings — which is exactly the indifference this has to survive.
  def event(event_type, payload)
    ActsAsTenant.without_tenant { AuditEvent.new(event_type: event_type, payload: payload) }
  end

  describe ".stream_name" do
    it "names the stream after the lead's public id" do
      expect(described_class.stream_name("L-1001")).to eq("verification:L-1001")
    end
  end

  describe ".for" do
    it "renders a completed layer as the panel's layer_result shape" do
      frame = described_class.for(event(Audit::Events::LAYER_COMPLETED,
                                        layer_key: "dnc", status: "completed", verdict: "callable",
                                        panel_verdict: "pass", detail: "callable, window open"))

      expect(frame).to eq(type: "layer_result", layer: "dnc", verdict: "pass",
                          detail: "callable, window open")
    end

    it "renders a skipped layer with the verdict the processor gave it" do
      frame = described_class.for(event(Audit::Events::LAYER_SKIPPED,
                                        layer_key: "voice", status: "not_applicable", verdict: nil,
                                        panel_verdict: "skip", detail: "no voice sample"))

      expect(frame).to include(type: "layer_result", layer: "voice", verdict: "skip")
    end

    it "renders an errored layer as a warning, never as a failure" do
      frame = described_class.for(event(Audit::Events::LAYER_ERRORED,
                                        layer_key: "anura", error_class: "Errors::ProviderUnavailable",
                                        error_message: "timed out"))

      expect(frame).to eq(type: "layer_result", layer: "anura", verdict: "warn",
                          detail: "layer unavailable")
    end

    it "upcases the verdict and expresses the score as a fraction the page can scale" do
      frame = described_class.for(event(Audit::Events::VERDICT_ISSUED,
                                        verdict: "accept", score: 90,
                                        reasons: [ "all enabled layers passed" ], flags: []))

      expect(frame).to eq(type: "final_verdict", verdict: "ACCEPT", score: 0.9,
                          reasons: [ "all enabled layers passed" ])
    end

    it "reads a payload that has been through the database just as it reads a fresh one" do
      account = create(:account)
      persisted = as_tenant(account) do
        create(:audit_event, account: account, event_type: Audit::Events::VERDICT_ISSUED,
                             payload: { verdict: "reject", score: 0, reasons: [ "DNC listed" ] }).reload
      end

      expect(described_class.for(persisted)).to eq(type: "final_verdict", verdict: "REJECT",
                                                   score: 0.0, reasons: [ "DNC listed" ])
    end

    it "announces reserved credits" do
      frame = described_class.for(event(Audit::Events::CREDITS_RESERVED, total: 17, balance_after: 400))

      expect(frame).to eq(type: "info", message: "credits reserved (17)")
    end

    it "announces settled credits" do
      frame = described_class.for(event(Audit::Events::CREDITS_SETTLED, refunded: 2, spent: 15))

      expect(frame).to eq(type: "info", message: "credits settled — 2 refunded")
    end

    it "announces an issued certificate by its public id" do
      frame = described_class.for(event(Audit::Events::CERTIFICATE_ISSUED,
                                        certificate_id: "cert_abc123", sequence_number: 4))

      expect(frame).to eq(type: "info", message: "certificate cert_abc123 issued")
    end

    it "returns nothing for events the panel does not render" do
      expect(described_class.for(event(Audit::Events::LAYER_STARTED, layer_key: "dnc"))).to be_nil
      expect(described_class.for(event(Audit::Events::AUTH_LOGIN_SUCCEEDED, {}))).to be_nil
    end
  end
end
