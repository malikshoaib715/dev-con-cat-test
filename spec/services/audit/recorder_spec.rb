require "rails_helper"

RSpec.describe Audit::Recorder do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  before { ActsAsTenant.current_tenant = account }

  it "captures the actor, the request context, and the tenant" do
    Current.user = user
    Current.account = account
    Current.request_id = "req_123"
    Current.session_id = "sess_abc"
    Current.ip_address = "203.0.113.9"

    event = described_class.record!(Audit::Events::LEAD_RECEIVED, payload: { source: "pixel" })

    expect(event).to have_attributes(
      event_type: Audit::Events::LEAD_RECEIVED,
      account_id: account.id,
      actor_type: "user",
      actor_id: user.id,
      request_id: "req_123",
      session_id: "sess_abc",
      ip_address: "203.0.113.9",
      payload: { "source" => "pixel" }
    )
  end

  it "attributes an event to the system when nobody is acting" do
    event = described_class.record!(Audit::Events::CREDITS_SETTLED, account: account)

    expect(event.actor_type).to eq("system")
    expect(event.actor_id).to be_nil
  end

  it "infers the tenant from the subject when no request context is set" do
    lead = create(:lead, account: account)
    Current.account = nil

    event = described_class.record!(Audit::Events::LEAD_RECEIVED, subject: lead)

    expect(event.account_id).to eq(account.id)
    expect(event.subject).to eq(lead)
  end

  it "records platform-level events that belong to no tenant at all" do
    ActsAsTenant.current_tenant = nil

    event = described_class.record!(Audit::Events::AUTH_LOGIN_FAILED, payload: { email: "nobody@example.com" })

    expect(event.account_id).to be_nil
  end

  it "hands the written event to the realtime broadcaster" do
    allow(Realtime::Broadcaster).to receive(:publish)

    event = described_class.record!(Audit::Events::LAYER_COMPLETED, account: account)

    expect(Realtime::Broadcaster).to have_received(:publish).with(event)
  end

  it "raises while we are developing, so a dropped event is never invisible" do
    expect { described_class.record!("not.a.real.event", account: account) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end

  it "never takes down the business flow in production" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

    expect(described_class.record!("not.a.real.event", account: account)).to be_nil
  end

  it "survives a broadcaster that blows up, because realtime is best effort" do
    allow(Realtime::Broadcaster).to receive(:publish).and_raise(StandardError, "cable down")
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

    expect { described_class.record!(Audit::Events::LAYER_COMPLETED, account: account) }.not_to raise_error
  end
end
