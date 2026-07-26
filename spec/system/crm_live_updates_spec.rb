require "rails_helper"

# The claim the audit spine makes, watched from the other end: one write feeds
# the visitor's live panel *and* the buyer's CRM. Nobody refreshes anything.
RSpec.describe "The CRM, while a lead is being captured", type: :system do
  before { load_static_seeds }

  let(:account) { fixture_account("acct_solarpro") }
  let(:pixel) { as_tenant(account) { Pixel.ordered.first } }

  before do
    load_provider_responses
    load_crm_records
    sign_in create(:user, account: account, role: "account_admin")
  end

  def submit_a_lead
    as_tenant(account) do
      Leads::IngestionService.call(
        pixel: pixel,
        attributes: { session_id: "sess_live_#{SecureRandom.hex(4)}",
                      ip_address: "76.14.201.33", page_url: "https://buyer.example.com/quote",
                      fields: { first_name: "Nadia", last_name: "Rahman",
                                email: "nadia.rahman@example.com", phone: "+13105550188" } }
      ).value.lead
    end
  end

  it "grows a row the moment a lead is captured, and fills its verdict in when the pipeline decides" do
    visit app_leads_path
    expect(page).to have_content("No leads match")

    lead = perform_enqueued_jobs { submit_a_lead }

    # Prepended by `lead.received`, then rewritten in place by `verdict.issued` —
    # the same two audit writes the pixel panel rendered.
    expect(page).to have_content(lead.public_id)
    expect(page).to have_content("Nadia Rahman")
    within("##{ActionView::RecordIdentifier.dom_id(lead)}") do
      expect(page).to have_content("ACCEPT")
    end
  end

  it "opens the lead it just grew" do
    lead = perform_enqueued_jobs { submit_a_lead }

    visit app_leads_path
    click_on "Nadia Rahman"

    expect(page).to have_content(lead.public_id)
    expect(page).to have_content("All ten")
    # The layer this account never bought, named rather than left blank.
    expect(page).to have_content("Not in plan")
  end
end
