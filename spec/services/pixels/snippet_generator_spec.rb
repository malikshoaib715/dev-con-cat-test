require "rails_helper"

RSpec.describe Pixels::SnippetGenerator do
  let(:account) { create(:account) }
  let(:pixel) { as_tenant(account) { create(:pixel, account: account, public_id: "px_9f2a01") } }

  before { as_tenant(account) { pixel.update!(public_key: "pk_testkey") } }

  it "builds the exact tag a buyer pastes into their head" do
    snippet = described_class.call(pixel: pixel, endpoint_base: "https://app.example")

    expect(snippet).to eq(
      '<script async src="https://app.example/super-pixel.js" ' \
      'data-pixel-id="px_9f2a01" data-pixel-key="pk_testkey" ' \
      'data-endpoint="https://app.example/api/pixel"></script>'
    )
  end

  # A base URL arriving with a trailing slash would otherwise produce
  # "//super-pixel.js", which some proxies treat as a different path entirely.
  it "does not double the separator when the base url ends in a slash" do
    snippet = described_class.call(pixel: pixel, endpoint_base: "https://app.example/")

    expect(snippet).to include('src="https://app.example/super-pixel.js"')
    expect(snippet).to include('data-endpoint="https://app.example/api/pixel"')
  end

  it "is async, so a buyer's page never waits for us" do
    expect(described_class.call(pixel: pixel, endpoint_base: "https://app.example")).to include("<script async ")
  end
end
