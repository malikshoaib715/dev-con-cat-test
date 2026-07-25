require "rails_helper"

RSpec.describe "Health check", type: :request do
  it "reports 200 once the application boots cleanly" do
    get "/up"

    expect(response).to have_http_status(:ok)
  end
end
