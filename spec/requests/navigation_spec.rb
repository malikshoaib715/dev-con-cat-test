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

  it "offers a platform operator the console, and none of the account surfaces" do
    sign_in create(:user, :super_admin)

    get admin_root_path

    expect(response.body).to include("Dashboard", "Accounts", "Audit", "Sidekiq")
    expect(response.body).not_to include(app_pixels_path)
    expect(response.body).not_to include("Review queue")
  end

  # The verifier is deliberately outside every tenant scope, and the nav renders
  # on it like anywhere else: the badge has to bring its own tenant.
  it "renders for a signed-in buyer on the public verifier, which has no tenant" do
    certificate = as_tenant(account) do
      run = create(:verification_run, account: account)
      create(:consent_certificate, account: account, verification_run: run, lead: run.lead)
    end
    sign_in create(:user, account: account, role: "member")

    get verify_certificate_path(certificate.public_id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Review queue")
  end

  it "marks the section the visitor is looking at" do
    sign_in create(:user, account: account, role: "member")

    get app_pixels_path

    expect(response.body).to match(%r{class="font-semibold text-slate-900" href="/app/pixels"})
  end
end
