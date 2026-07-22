require "rails_helper"

RSpec.describe AuditEvent do
  let(:account) { create(:account) }

  before { ActsAsTenant.current_tenant = account }

  it "is append-only: a persisted event cannot be edited" do
    event = create(:audit_event, account: account)

    expect(event).to be_readonly
    expect { event.update!(payload: { tampered: true }) }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "refuses an event type outside the frozen taxonomy" do
    event = build(:audit_event, account: account, event_type: "lead.vibes_checked")

    expect(event).not_to be_valid
  end

  it "finds every event belonging to a subject" do
    lead = create(:lead, account: account)
    mine = create(:audit_event, account: account, subject: lead)
    create(:audit_event, account: account)

    expect(described_class.for_subject(lead)).to contain_exactly(mine)
  end

  it "correlates the whole capture session, from visit beacon to verdict" do
    create(:audit_event, account: account, event_type: Audit::Events::PIXEL_VISIT_RECORDED, session_id: "sess_abc")
    create(:audit_event, account: account, event_type: Audit::Events::LEAD_RECEIVED,        session_id: "sess_abc")
    create(:audit_event, account: account, event_type: Audit::Events::LEAD_RECEIVED,        session_id: "sess_other")

    expect(described_class.for_session("sess_abc").count).to eq(2)
  end
end
