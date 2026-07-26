require "rails_helper"

RSpec.describe "The platform console", type: :request do
  let(:solar) { create(:account, name: "SolarPro", credit_balance: 400, monthly_credit_allowance: 500) }

  # The seeded shape of acct_autoinsure: past due, and spending faster than it
  # has left. This is the row an operator has to notice.
  let(:autoinsure) do
    create(:account, name: "AutoInsure Direct", status: "past_due",
                     credit_balance: 8, monthly_credit_allowance: 200,
                     settings: { "avg_daily_burn" => 96 })
  end

  let(:operator) { create(:user, :super_admin) }

  describe "who may reach it" do
    # 404 rather than 403: the console's existence is not advertised to tenants.
    it "is invisible to an account admin" do
      sign_in create(:user, :account_admin, account: solar)

      get admin_root_path
      expect(response).to have_http_status(:not_found)

      get admin_accounts_path
      expect(response).to have_http_status(:not_found)

      get admin_audit_events_path
      expect(response).to have_http_status(:not_found)
    end

    it "is invisible to a member" do
      sign_in create(:user, account: solar, role: "member")

      get admin_root_path

      expect(response).to have_http_status(:not_found)
    end

    it "sends an anonymous visitor to sign in" do
      get admin_root_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "the dashboard" do
    before do
      solar
      autoinsure
      sign_in operator
    end

    it "lists every account on the platform" do
      get admin_root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("SolarPro", "AutoInsure Direct")
    end

    it "flags the account that is past due and about to run dry" do
      get admin_root_path

      expect(response.body).to include(Platform::AccountSummary::PAST_DUE)
      expect(response.body).to include(Platform::AccountSummary::LOW_CREDIT)
    end

    it "leaves a healthy account unflagged" do
      get admin_root_path

      expect(response.body.scan(/⚠/).size).to eq(2)
    end

    it "splits the platform's verdicts three ways" do
      as_tenant(solar) do
        create(:consensus_verdict, account: solar, verdict: "accept")
        create(:consensus_verdict, account: solar, verdict: "review")
      end

      get admin_root_path

      expect(response.body).to include("ACCEPT", "REVIEW", "REJECT")
    end

    it "shows recent events from more than one account, which is the point of it" do
      solar_event = as_tenant(solar) { create(:audit_event, account: solar, payload: { "note" => "solar-write" }) }
      other_event = as_tenant(autoinsure) do
        create(:audit_event, account: autoinsure, payload: { "note" => "autoinsure-write" })
      end

      get admin_root_path

      expect(response.body).to include(solar_event.payload["note"], other_event.payload["note"])
    end
  end

  describe "an account drill-down" do
    before { sign_in operator }

    it "reads another tenant's position without opening any way to change it" do
      as_tenant(solar) do
        create(:lead, account: solar, verdict: "accept", status: "completed")
        create(:credit_ledger_entry, account: solar, entry_type: "grant", amount: 500,
                                     balance_after: 500, memo: "monthly allowance")
        create(:pixel, account: solar, name: "Quote form")
      end

      get admin_account_path(solar)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("monthly allowance", "Quote form")
      # Nothing on the page posts back into the console. (Signing out, in the
      # nav, is the only form on any page here.)
      expect(response.body).not_to match(%r{<form[^>]*action="/admin})
    end

    it "is addressed by the account's public id" do
      get admin_account_path(solar)

      expect(request.path).to end_with(solar.public_id)
    end

    it "has nothing to show for an account that does not exist" do
      get admin_account_path("acct_nonexistent")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the platform explorer" do
    before { sign_in operator }

    it "returns events from every account in one list" do
      mine = as_tenant(solar) { create(:audit_event, account: solar, payload: { "note" => "solar-write" }) }
      theirs = as_tenant(autoinsure) do
        create(:audit_event, account: autoinsure, payload: { "note" => "autoinsure-write" })
      end

      get admin_audit_events_path

      expect(response.body).to include(mine.payload["note"], theirs.payload["note"])
    end

    it "narrows to one account when asked" do
      mine = as_tenant(solar) { create(:audit_event, account: solar, payload: { "note" => "solar-write" }) }
      theirs = as_tenant(autoinsure) do
        create(:audit_event, account: autoinsure, payload: { "note" => "autoinsure-write" })
      end

      get admin_audit_events_path(account_id: solar.id)

      expect(response.body).to include(mine.payload["note"])
      expect(response.body).not_to include(theirs.payload["note"])
    end

    it "narrows by event type, the same way the account explorer does" do
      as_tenant(solar) do
        create(:audit_event, account: solar, event_type: Audit::Events::CREDITS_RESERVED,
                             payload: { "total" => 17 })
        create(:audit_event, account: solar, event_type: Audit::Events::LAYER_COMPLETED,
                             payload: { "layer_key" => "dnc" })
      end

      get admin_audit_events_path(event_type: Audit::Events::CREDITS_RESERVED)

      expect(response.body).to include("total: 17")
      expect(response.body).not_to include("layer_key: dnc")
    end

    it "names the account each event belongs to" do
      as_tenant(solar) { create(:audit_event, account: solar) }

      get admin_audit_events_path

      expect(response.body).to include("SolarPro")
    end
  end
end
