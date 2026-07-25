require "rails_helper"

RSpec.describe "Demo", type: :request do
  it "carries the snippet the generator produces, character for character" do
    load_static_seeds
    pixel = ActsAsTenant.without_tenant { Pixel.find_by!(public_id: DemoController::DEMO_PIXEL_PUBLIC_ID) }

    get "/demo"

    expect(response.body).to include(
      Pixels::SnippetGenerator.call(pixel: pixel, endpoint_base: "http://www.example.com")
    )
  end

  it "is public: a visitor filling in a buyer's form has no account with us" do
    load_static_seeds

    get "/demo"

    expect(response).to have_http_status(:ok)
  end

  # A fresh clone with no seeds should say so, rather than failing in a way that
  # reads as the demo being broken.
  it "explains itself when the demo pixel has not been seeded" do
    get "/demo"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("db:seed")
  end
end
