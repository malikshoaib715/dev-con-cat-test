require "rails_helper"

RSpec.describe "App::Leads", type: :request do
  let(:solar)    { create(:account, name: "SolarPro") }
  let(:medicare) { create(:account, name: "MedicareEdge") }

  let!(:solar_lead) do
    as_tenant(solar) { create(:lead, account: solar, first_name: "Maria", last_name: "Gonzalez") }
  end

  let!(:medicare_lead) do
    as_tenant(medicare) { create(:lead, account: medicare, first_name: "Daniel", last_name: "Okafor") }
  end

  it "shows a member only their own account's leads" do
    sign_in create(:user, account: solar, role: "member")

    get app_leads_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(solar_lead.public_id)
    expect(response.body).not_to include(medicare_lead.public_id)
  end

  it "shows the other account's leads to that account's users, and only those" do
    sign_in create(:user, account: medicare, role: "member")

    get app_leads_path

    expect(response.body).to include(medicare_lead.public_id)
    expect(response.body).not_to include(solar_lead.public_id)
  end

  it "has nothing to show a platform operator, who has no tenant of their own" do
    sign_in create(:user, :super_admin)

    get app_leads_path

    expect(response).to have_http_status(:not_found)
  end

  it "sends an anonymous visitor to sign in" do
    get app_leads_path

    expect(response).to redirect_to(new_user_session_path)
  end

  describe "filtering" do
    let(:member) { create(:user, account: solar, role: "member") }

    let!(:accepted) do
      as_tenant(solar) { create(:lead, account: solar, verdict: "accept", status: "completed") }
    end

    let!(:held) do
      as_tenant(solar) { create(:lead, account: solar, status: "on_hold_insufficient_credits") }
    end

    let!(:flagged) do
      as_tenant(solar) do
        create(:lead, account: solar, verdict: "accept", status: "completed", flags: [ "soft_duplicate" ])
      end
    end

    before { sign_in member }

    it "narrows to one verdict" do
      get app_leads_path(verdict: "accept")

      expect(response.body).to include(accepted.public_id, flagged.public_id)
      expect(response.body).not_to include(held.public_id)
    end

    it "narrows to one status" do
      get app_leads_path(status: "on_hold_insufficient_credits")

      expect(response.body).to include(held.public_id)
      expect(response.body).not_to include(accepted.public_id)
    end

    it "narrows to leads carrying a flag" do
      get app_leads_path(flag: "soft_duplicate")

      expect(response.body).to include(flagged.public_id)
      expect(response.body).not_to include(accepted.public_id)
    end

    it "narrows to a date range on when the lead was submitted" do
      old_lead = as_tenant(solar) { create(:lead, account: solar, submitted_at: 10.days.ago) }

      get app_leads_path(from: 2.days.ago.to_date.to_s)

      expect(response.body).to include(accepted.public_id)
      expect(response.body).not_to include(old_lead.public_id)
    end

    it "includes a lead submitted on the closing day of the range" do
      get app_leads_path(from: Date.current.to_s, to: Date.current.to_s)

      expect(response.body).to include(accepted.public_id)
    end

    it "combines filters rather than letting the last one win" do
      get app_leads_path(verdict: "accept", flag: "soft_duplicate")

      expect(response.body).to include(flagged.public_id)
      expect(response.body).not_to include(accepted.public_id)
    end

    # A hand-edited URL is a bad query, not a server error.
    it "ignores a filter value the pipeline could never have written" do
      get app_leads_path(verdict: "definitely-not-a-verdict")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(accepted.public_id, held.public_id)
    end

    it "offers the review queue as a filtered link rather than a second page" do
      review = as_tenant(solar) { create(:lead, account: solar, verdict: "review", status: "completed") }

      get app_leads_path(verdict: "review")

      expect(response.body).to include(review.public_id)
      expect(response.body).not_to include(accepted.public_id)
    end
  end

  describe "searching" do
    let!(:searchable) do
      as_tenant(solar) do
        create(:lead, account: solar, first_name: "Patricia", last_name: "Whitfield",
                      email: "p.whitfield@example.com", email_normalized: "p.whitfield@example.com",
                      phone: "+16465550193", phone_normalized: "+16465550193")
      end
    end

    before { sign_in create(:user, account: solar, role: "member") }

    # A buyer types the number the way their call sheet prints it; the normalizer
    # is what makes that the same search as the stored E.164 form.
    it "finds a lead by a phone number typed the way a human writes one" do
      get app_leads_path(q: "(646) 555-0193")

      expect(response.body).to include(searchable.public_id)
      expect(response.body).not_to include(solar_lead.public_id)
    end

    it "finds a lead by email address, whatever case it is typed in" do
      get app_leads_path(q: "P.Whitfield@Example.com")

      expect(response.body).to include(searchable.public_id)
    end

    it "finds a lead by part of a name" do
      get app_leads_path(q: "whitfi")

      expect(response.body).to include(searchable.public_id)
      expect(response.body).not_to include(solar_lead.public_id)
    end

    it "finds a lead by first and last name together" do
      get app_leads_path(q: "Patricia Whitfield")

      expect(response.body).to include(searchable.public_id)
    end

    it "never reaches into another account, however well the term matches" do
      twin = as_tenant(medicare) do
        create(:lead, account: medicare, first_name: "Patricia", last_name: "Whitfield",
                      phone: "+16465550193", phone_normalized: "+16465550193")
      end

      get app_leads_path(q: "+16465550193")

      expect(response.body).to include(searchable.public_id)
      expect(response.body).not_to include(twin.public_id)
    end
  end
end
