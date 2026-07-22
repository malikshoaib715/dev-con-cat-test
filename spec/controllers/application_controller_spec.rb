require "rails_helper"

# The HTML side of the error map: a record that belongs to somebody else is
# reported as missing, and a role that is not allowed to act is told so plainly.
RSpec.describe ApplicationController, type: :controller do
  render_views

  controller do
    def index
      raise params[:raise].constantize
    end
  end

  let(:account) { create(:account) }

  before { sign_in create(:user, account: account) }

  it "reports a record it cannot see as missing, never as forbidden" do
    get :index, params: { raise: "ActiveRecord::RecordNotFound" }

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("belongs to another account")
  end

  it "reports an untenanted query as missing too, rather than leaking the failure" do
    get :index, params: { raise: "ActsAsTenant::Errors::NoTenantSet" }

    expect(response).to have_http_status(:not_found)
  end

  it "tells a user whose role forbids the action, inside their own account" do
    get :index, params: { raise: "Pundit::NotAuthorizedError" }

    expect(response).to have_http_status(:forbidden)
    expect(response.body).to include("Your role does not permit that action")
  end
end
