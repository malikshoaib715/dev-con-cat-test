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
end
