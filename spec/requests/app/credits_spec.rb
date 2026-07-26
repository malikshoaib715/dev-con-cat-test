require "rails_helper"

RSpec.describe "App::Credits", type: :request do
  let(:solar) { create(:account, name: "SolarPro", credit_balance: 80, monthly_credit_allowance: 400) }
  let(:medicare) { create(:account, name: "MedicareEdge") }

  it "shows the balance, what it is being spent at, and how long it lasts" do
    as_tenant(solar) do
      create(:credit_ledger_entry, account: solar, entry_type: "reservation",
                                   amount: -140, balance_after: 80, created_at: 1.day.ago)
    end
    sign_in create(:user, account: solar, role: "member")

    get app_credits_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("80")
    expect(response.body).to include("days")
  end

  it "reports an account that has spent nothing as never running out" do
    sign_in create(:user, account: solar, role: "member")

    get app_credits_path

    expect(response.body).to include("∞")
  end

  it "shows what each layer of a movement cost" do
    as_tenant(solar) do
      run = create(:verification_run, account: solar)
      create(:credit_ledger_entry, account: solar, verification_run: run,
                                   entry_type: "settlement_refund", amount: 4, balance_after: 84,
                                   breakdown: { "voice" => 4 }, memo: "settlement for #{run.lead.public_id}")
    end
    sign_in create(:user, account: solar, role: "member")

    get app_credits_path

    expect(response.body).to include(Layers::Registry.label("voice"))
    expect(response.body).to include("+4")
  end

  it "names the lead each movement was for" do
    lead_id = as_tenant(solar) do
      run = create(:verification_run, account: solar)
      create(:credit_ledger_entry, account: solar, verification_run: run, entry_type: "reservation",
                                   amount: -17, balance_after: 63)
      run.lead.public_id
    end
    sign_in create(:user, account: solar, role: "member")

    get app_credits_path

    expect(response.body).to include(lead_id)
  end

  it "never shows one account another account's ledger" do
    theirs = as_tenant(medicare) do
      create(:credit_ledger_entry, account: medicare, entry_type: "grant", amount: 999,
                                   balance_after: 999, memo: "medicare grant")
    end
    sign_in create(:user, account: solar, role: "member")

    get app_credits_path

    expect(response.body).not_to include(theirs.memo)
  end

  it "sends a platform operator, who has no ledger of their own, nowhere" do
    sign_in create(:user, :super_admin)

    get app_credits_path

    expect(response).to have_http_status(:not_found)
  end
end
