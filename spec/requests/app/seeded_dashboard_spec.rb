require "rails_helper"

# The phase gate, written down: the dashboards read against the twelve seeded
# leads rather than against fixtures invented for the assertion. If the engine's
# verdicts and these pages ever disagree, this is what says so.
RSpec.describe "The dashboards, against the seeded world", :seeded_world, type: :request do
  def sign_in_to(account_public_id, role: "account_admin")
    account = Account.find_by!(public_id: account_public_id)
    sign_in create(:user, account: account, role: role)
    account
  end

  describe "the review queue" do
    it "holds SolarPro's one undecided lead and neither of its rejects" do
      sign_in_to("acct_solarpro")

      get app_leads_path(verdict: "review")

      expect(response.body).to include("L-1007")
      expect(response.body).not_to include("L-1002", "L-1010")
    end

    it "holds MedicareEdge's three" do
      sign_in_to("acct_medicareedge")

      get app_leads_path(verdict: "review")

      expect(response.body).to include("L-1003", "L-1008", "L-1011")
      expect(response.body).not_to include("L-1004")
    end

    it "counts the same leads in the nav badge as the page lists" do
      account = sign_in_to("acct_solarpro")
      waiting = ActsAsTenant.with_tenant(account) { account.leads.with_verdict("review").count }

      get app_leads_path

      expect(response.body).to match(/Review queue.*>#{waiting}</m)
    end
  end

  # Accepted, and flagged for a human all the same: same phone as an existing
  # customer, different address. A soft duplicate is surfaced, never auto-rejected.
  it "shows L-1012 accepted while still wearing its soft-duplicate flag" do
    sign_in_to("acct_autoinsure")

    get app_leads_path(flag: "soft_duplicate")

    expect(response.body).to include("L-1012")
    expect(response.body).to include("Soft duplicate")
  end

  it "names the layer that hard-stopped L-1005 — the do-not-call list, not the litigator layer AutoInsure never bought" do
    account = sign_in_to("acct_autoinsure")
    lead = ActsAsTenant.with_tenant(account) { account.leads.find_by!(public_id: "L-1005") }

    get app_lead_path(lead)

    expect(response.body).to include("Hard stop: #{Layers::Registry.label('dnc')}")
    expect(response.body).to include("Not in plan")
  end

  it "verifies every certificate the seeds issued" do
    account = sign_in_to("acct_solarpro")
    certificates = ActsAsTenant.with_tenant(account) { account.consent_certificates.chain_order.to_a }

    expect(certificates).not_to be_empty

    certificates.each do |certificate|
      get app_certificate_path(certificate)

      expect(response.body).to include("VALID")
      expect(response.body).not_to include("TAMPERED")
    end
  end

  it "reconciles the credits page with the ledger the seeds wrote" do
    account = sign_in_to("acct_autoinsure")

    get app_credits_path

    expect(response.body).to include(number_with_delimiter(account.credit_balance))
  end

  it "lights up the account that is past due and about to run dry" do
    sign_in create(:user, :super_admin)

    get admin_root_path

    expect(response.body).to include("AutoInsure")
    expect(response.body).to include(Platform::AccountSummary::PAST_DUE)
    expect(response.body).to include(Platform::AccountSummary::LOW_CREDIT)
  end

  private

  def number_with_delimiter(value)
    ActiveSupport::NumberHelper.number_to_delimited(value)
  end
end
