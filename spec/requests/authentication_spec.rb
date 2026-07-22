require "rails_helper"

RSpec.describe "Authentication", type: :request do
  let(:account) { create(:account) }
  let!(:user)   { create(:user, account: account, email: "dana@buyer.example", password: "Sup3rPixel!pw") }

  def sign_in_with(email:, password:)
    post user_session_path, params: { user: { email: email, password: password } }
  end

  def audit_events_of(event_type)
    ActsAsTenant.without_tenant { AuditEvent.of_type(event_type) }
  end

  describe "signing in" do
    it "lands an account user on their dashboard and records the event" do
      sign_in_with(email: user.email, password: "Sup3rPixel!pw")

      expect(response).to redirect_to(authenticated_root_path)
      expect(audit_events_of(Audit::Events::AUTH_LOGIN_SUCCEEDED).count).to eq(1)
      expect(audit_events_of(Audit::Events::AUTH_LOGIN_SUCCEEDED).first.account_id).to eq(account.id)
    end

    it "rejects a wrong password and records the failed attempt" do
      sign_in_with(email: user.email, password: "not-the-password")

      expect(response).to have_http_status(:unprocessable_content)
      failure = audit_events_of(Audit::Events::AUTH_LOGIN_FAILED).first
      expect(failure.payload["email"]).to eq("dana@buyer.example")
    end

    it "records a failed attempt for an email that does not exist without leaking that it does not" do
      sign_in_with(email: "ghost@buyer.example", password: "whatever")

      expect(response).to have_http_status(:unprocessable_content)
      expect(audit_events_of(Audit::Events::AUTH_LOGIN_FAILED).count).to eq(1)
      expect(audit_events_of(Audit::Events::AUTH_LOGIN_FAILED).first.account_id).to be_nil
    end

    it "offers no self-service registration route" do
      expect { new_user_registration_path }.to raise_error(NameError)
    end
  end

  describe "signing out" do
    it "records the logout" do
      sign_in user

      delete destroy_user_session_path

      expect(audit_events_of(Audit::Events::AUTH_LOGOUT).count).to eq(1)
    end
  end

  describe "brute force protection", throttling: true do
    it "throttles repeated failures against one mailbox" do
      6.times { sign_in_with(email: user.email, password: "wrong-#{rand}") }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.dig("error", "code")).to eq("throttled")
      # The same envelope the pixel API uses, carrying a real request id.
      expect(response.parsed_body.dig("error", "request_id")).to be_present
      expect(audit_events_of(Audit::Events::API_THROTTLED)).to be_any
    end
  end

  describe "the job console" do
    it "is reachable by a platform operator" do
      sign_in create(:user, :super_admin)

      get "/admin/sidekiq"

      expect(response).to have_http_status(:ok)
    end

    it "does not exist for an account user" do
      sign_in user

      get "/admin/sidekiq"

      expect(response).to have_http_status(:not_found)
    end

    it "does not exist for an anonymous visitor" do
      get "/admin/sidekiq"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "a protected page" do
    it "sends an anonymous visitor to the sign-in screen" do
      get app_leads_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
