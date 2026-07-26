require "rails_helper"

# Asserted against the transport rather than through Action Cable's own matchers,
# which need the `test` adapter: cable.yml deliberately runs `async` in test so the
# system spec in 4.4 exercises real delivery over a real socket. This spec owns the
# narrower question — what the broadcaster sends, and where.
RSpec.describe Realtime::Broadcaster do
  let(:account) { create(:account) }
  let(:lead) { as_tenant(account) { create(:lead, account: account) } }
  let(:stream) { "verification:#{lead.public_id}" }

  before { allow(ActionCable.server).to receive(:broadcast) }

  def record(event_type, payload)
    as_tenant(account) do
      Audit::Recorder.record!(event_type, subject: lead, payload: payload, actor: nil, account: account)
    end
  end

  it "broadcasts a verdict to the lead's own stream as the audit event is written" do
    event = record(Audit::Events::VERDICT_ISSUED, verdict: "accept", score: 90, reasons: [ "clean" ], flags: [])

    expect(ActionCable.server).to have_received(:broadcast)
      .with(stream, type: "final_verdict", verdict: "ACCEPT", score: 0.9, reasons: [ "clean" ],
                    id: event.id)
  end

  # The id is the two transports' shared vocabulary: the pixel's catch-up read
  # re-fetches what was broadcast before its subscription was confirmed, and
  # only the id says "you have already painted this one".
  it "stamps the socket frame with the event id the polling response carries" do
    event = record(Audit::Events::LAYER_COMPLETED, layer_key: "dnc", status: "completed",
                                                   panel_verdict: "pass", detail: "callable")

    expect(ActionCable.server).to have_received(:broadcast)
      .with(stream, hash_including(id: event.id))
  end

  it "broadcasts a layer result to the lead's own stream" do
    record(Audit::Events::LAYER_COMPLETED, layer_key: "dnc", status: "completed",
                                           panel_verdict: "pass", detail: "callable, window open")

    expect(ActionCable.server).to have_received(:broadcast)
      .with(stream, hash_including(type: "layer_result", layer: "dnc", verdict: "pass"))
  end

  it "never sends one lead's activity to another lead's stream" do
    other_lead = as_tenant(account) { create(:lead, account: account) }

    record(Audit::Events::LAYER_COMPLETED, layer_key: "dnc", panel_verdict: "pass", detail: "callable")

    expect(ActionCable.server).not_to have_received(:broadcast)
      .with("verification:#{other_lead.public_id}", anything)
  end

  it "stays silent for events the panel does not render" do
    record(Audit::Events::LAYER_STARTED, layer_key: "dnc")

    expect(ActionCable.server).not_to have_received(:broadcast)
  end

  it "stays silent for events that belong to no lead" do
    event = as_tenant(account) do
      create(:audit_event, account: account, event_type: Audit::Events::AUTH_LOGIN_SUCCEEDED)
    end

    described_class.publish(event)

    expect(ActionCable.server).not_to have_received(:broadcast)
  end

  # Realtime is best-effort. A dead socket must never take down the verification
  # that was trying to report through it — the row is already written, and the
  # polling fallback can still read it.
  it "swallows and logs a transport failure rather than failing the audit write" do
    allow(ActionCable.server).to receive(:broadcast).and_raise(IOError, "connection reset")
    allow(Rails.logger).to receive(:error)

    expect {
      record(Audit::Events::VERDICT_ISSUED, verdict: "accept", score: 90, reasons: [], flags: [])
    }.not_to raise_error

    # Both consumers ride the same transport, so both report it dead.
    expect(Rails.logger).to have_received(:error).with(/realtime-drop.*IOError/).at_least(:once)
  end
end
