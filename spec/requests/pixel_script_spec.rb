require "rails_helper"

# The pixel is the one public file whose URL is permanent: it is baked into
# every buyer's snippet, so it can never be content-addressed the way a digested
# asset is. Served with the long max-age the rest of `public/` gets, a browser
# that fetched it once would not ask again for as long as that header lasts —
# and a corrected pixel would reach nobody already carrying the old one.
RSpec.describe "GET /super-pixel.js" do
  it "is cached but revalidated, so a fix reaches a browser that already has it" do
    get "/super-pixel.js"

    expect(response).to have_http_status(:ok)
    expect(response.headers["cache-control"]).to eq(PixelCacheControl::POLICY)
    expect(response.headers["cache-control"]).to include("must-revalidate")
  end

  it "still serves the script itself" do
    get "/super-pixel.js"

    expect(response.media_type).to eq("text/javascript")
    expect(response.body).to include("SuperPixel")
  end

  # The long-lived header is right for everything else under public/, and this
  # middleware must not have taken it away from them.
  it "leaves the rest of public/ on its own caching policy" do
    get "/robots.txt"

    expect(response.headers["cache-control"]).not_to eq(PixelCacheControl::POLICY)
  end
end
