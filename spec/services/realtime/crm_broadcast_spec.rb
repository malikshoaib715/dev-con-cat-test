require "rails_helper"

RSpec.describe Realtime::CrmBroadcast do
  let(:account) { create(:account) }
  let(:lead) { as_tenant(account) { create(:lead, account: account) } }
  let(:stream) { "account_#{account.public_id}_leads" }

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  def record(event_type, payload = {})
    as_tenant(account) do
      Audit::Recorder.record!(event_type, subject: lead, payload: payload, actor: nil, account: account)
    end
  end

  it "puts a newly captured lead at the top of its own account's table" do
    record(Audit::Events::LEAD_RECEIVED)

    expect(Turbo::StreamsChannel).to have_received(:broadcast_prepend_to)
      .with(stream, target: "leads", partial: "app/leads/lead", locals: { lead: lead })
  end

  it "rewrites the lead's row in place when its verdict is issued" do
    record(Audit::Events::VERDICT_ISSUED, verdict: "reject", score: 0, reasons: [], flags: [])

    expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to)
      .with(stream, target: "lead_#{lead.id}", partial: "app/leads/lead", locals: { lead: lead })
  end

  it "never sends one account's lead to another account's table" do
    other_account = create(:account)

    record(Audit::Events::LEAD_RECEIVED)

    expect(Turbo::StreamsChannel).not_to have_received(:broadcast_prepend_to)
      .with("account_#{other_account.public_id}_leads", anything)
  end

  it "stays quiet for the events in between, which change no row" do
    record(Audit::Events::LAYER_COMPLETED, layer_key: "dnc", panel_verdict: "pass", detail: "callable")

    expect(Turbo::StreamsChannel).not_to have_received(:broadcast_prepend_to)
    expect(Turbo::StreamsChannel).not_to have_received(:broadcast_replace_to)
  end

  # The CRM losing a row update must not take the live panel down with it, nor the
  # verification that was reporting through both.
  it "is swallowed and logged when the stream cannot be reached" do
    allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to).and_raise(IOError, "connection reset")
    allow(Rails.logger).to receive(:error)

    expect { record(Audit::Events::LEAD_RECEIVED) }.not_to raise_error
    expect(Rails.logger).to have_received(:error).with(/realtime-drop.*IOError/)
  end

  it "still reaches the live panel when the CRM broadcast fails" do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to).and_raise(IOError, "connection reset")
    allow(Rails.logger).to receive(:error)
    allow(ActionCable.server).to receive(:broadcast)

    record(Audit::Events::VERDICT_ISSUED, verdict: "accept", score: 90, reasons: [], flags: [])

    expect(ActionCable.server).to have_received(:broadcast)
      .with("verification:#{lead.public_id}", hash_including(type: "final_verdict"))
  end
end
