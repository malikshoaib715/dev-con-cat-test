require "rails_helper"

RSpec.describe Admin::BaseController, type: :controller do
  controller do
    def index
      render plain: Lead.count.to_s
    end
  end

  let(:solar)    { create(:account) }
  let(:medicare) { create(:account) }

  before do
    as_tenant(solar)    { create(:lead, account: solar) }
    as_tenant(medicare) { create(:lead, account: medicare) }
  end

  it "spans every account for a platform operator" do
    sign_in create(:user, :super_admin)

    get :index

    expect(response.body).to eq("2")
  end

  it "is not visible to an account admin" do
    sign_in create(:user, :account_admin, account: solar)

    get :index

    expect(response).to have_http_status(:not_found)
  end

  it "is not visible to a member" do
    sign_in create(:user, account: solar, role: "member")

    get :index

    expect(response).to have_http_status(:not_found)
  end

  it "sends an anonymous visitor to sign in" do
    get :index

    expect(response).to redirect_to(new_user_session_path)
  end
end
