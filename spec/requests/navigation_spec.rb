require "rails_helper"

RSpec.describe "Navigation", type: :request do
  let(:account) { create(:account) }

  it "offers an account user the surfaces their account owns" do
    sign_in create(:user, account: account, role: "account_admin")

    get app_leads_path

    expect(response.body).to include("Leads", "Review queue", "Pixels")
  end

  it "counts the leads waiting on a human next to the review queue" do
    as_tenant(account) { create_list(:lead, 2, account: account, verdict: "review") }
    sign_in create(:user, account: account, role: "member")

    get app_leads_path

    expect(response.body).to match(/Review queue.*>2</m)
  end

  it "shows no count when nothing is waiting on a human" do
    sign_in create(:user, account: account, role: "member")

    get app_leads_path

    expect(response.body).to include("Review queue")
    expect(response.body).not_to match(/Review queue.*>0</m)
  end

  it "marks the section the visitor is looking at" do
    sign_in create(:user, account: account, role: "member")

    get app_pixels_path

    expect(response.body).to match(%r{class="font-semibold text-slate-900" href="/app/pixels"})
  end
end
