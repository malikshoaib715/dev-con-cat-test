require "rails_helper"

RSpec.describe "App::AuditEvents", type: :request do
  let(:solar) { create(:account, name: "SolarPro") }
  let(:medicare) { create(:account, name: "MedicareEdge") }
  let(:lead) { as_tenant(solar) { create(:lead, account: solar, session_id: "sess_solar_1") } }

  def event_for(account, **overrides)
    as_tenant(account) { create(:audit_event, account: account, **overrides) }
  end

  before { sign_in create(:user, account: solar, role: "member") }

  it "shows the account's events newest first" do
    received = event_for(solar, event_type: Audit::Events::LEAD_RECEIVED, subject: lead)

    get app_audit_events_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(received.event_type)
  end

  it "narrows to one kind of event" do
    event_for(solar, event_type: Audit::Events::CREDITS_RESERVED, payload: { "total" => 17 })
    event_for(solar, event_type: Audit::Events::LAYER_COMPLETED, payload: { "layer_key" => "dnc" })

    get app_audit_events_path(event_type: Audit::Events::CREDITS_RESERVED)

    expect(response.body).to include("total: 17")
    expect(response.body).not_to include("layer_key: dnc")
  end

  # The link the lead timeline offers: the same set of rows, in the explorer.
  it "reproduces a lead's timeline when filtered by its session" do
    mine = event_for(solar, session_id: lead.session_id, payload: { "page_url" => "https://buyer.example.com/a" })
    other = event_for(solar, session_id: "sess_solar_2", payload: { "page_url" => "https://buyer.example.com/b" })

    get app_audit_events_path(session_id: lead.session_id)

    expect(response.body).to include(mine.payload["page_url"])
    expect(response.body).not_to include(other.payload["page_url"])
  end

  it "narrows to one record" do
    about_lead = event_for(solar, subject: lead, payload: { "note" => "about-the-lead" })
    about_nothing = event_for(solar, subject: nil, payload: { "note" => "about-nothing" })

    get app_audit_events_path(subject_type: "Lead", subject_id: lead.id)

    expect(response.body).to include(about_lead.payload["note"])
    expect(response.body).not_to include(about_nothing.payload["note"])
  end

  it "narrows by when the event happened" do
    recent = event_for(solar, occurred_at: 1.hour.ago, payload: { "note" => "today" })
    old = event_for(solar, occurred_at: 10.days.ago, payload: { "note" => "last-week" })

    get app_audit_events_path(from: 2.days.ago.to_date.to_s)

    expect(response.body).to include(recent.payload["note"])
    expect(response.body).not_to include(old.payload["note"])
  end

  it "ignores an event type the taxonomy does not contain" do
    event_for(solar, payload: { "note" => "still-here" })

    get app_audit_events_path(event_type: "lead.invented")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("still-here")
  end

  # Deliberately colliding the session id: tenancy, not the correlation id, is
  # what keeps these apart.
  it "never returns another account's events, even one sharing a session id" do
    theirs = event_for(medicare, session_id: lead.session_id, payload: { "note" => "other-tenant" })

    get app_audit_events_path(session_id: lead.session_id)

    expect(response.body).not_to include(theirs.payload["note"])
  end

  it "links a lead subject through to the lead" do
    event_for(solar, subject: lead)

    get app_audit_events_path

    expect(response.body).to include(app_lead_path(lead))
  end
end
