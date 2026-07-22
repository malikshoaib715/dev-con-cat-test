require "rails_helper"

RSpec.describe Pixel do
  let(:account) { create(:account) }

  before { ActsAsTenant.current_tenant = account }

  it "generates a public id and a public key on create" do
    pixel = create(:pixel, account: account)

    expect(pixel.public_id).to start_with("px_")
    expect(pixel.public_key).to start_with("pk_")
  end

  it "rejects layer keys that are not in the canonical registry" do
    pixel = build(:pixel, account: account, enabled_layers: %w[anura trusted_form])

    expect(pixel).not_to be_valid
    expect(pixel.errors[:enabled_layers].join).to include("trusted_form")
  end

  describe "#effective_layer_keys" do
    it "is the intersection of what the account pays for and what the pixel advertises" do
      create(:layer_policy, account: account, layer_key: "anura", enabled: true)
      create(:layer_policy, account: account, layer_key: "dnc",   enabled: true)
      create(:layer_policy, account: account, layer_key: "voice", enabled: false)
      pixel = create(:pixel, account: account, enabled_layers: %w[anura voice])

      expect(pixel.effective_layer_keys).to eq(%w[anura])
    end

    it "returns the layers in registry order regardless of how they were stored" do
      create(:layer_policy, account: account, layer_key: "dnc",   enabled: true)
      create(:layer_policy, account: account, layer_key: "anura", enabled: true)
      pixel = create(:pixel, account: account, enabled_layers: %w[dnc anura])

      expect(pixel.effective_layer_keys).to eq(%w[anura dnc])
    end
  end

  describe "#allows_origin?" do
    let(:pixel) { create(:pixel, account: account, allowed_domains: %w[buyer.example.com localhost]) }

    it "accepts an allowed host on any port" do
      expect(pixel.allows_origin?("http://localhost:3000")).to be(true)
      expect(pixel.allows_origin?("https://buyer.example.com")).to be(true)
    end

    it "rejects an unlisted host, a blank origin, and an unparseable one" do
      expect(pixel.allows_origin?("https://attacker.example.com")).to be(false)
      expect(pixel.allows_origin?(nil)).to be(false)
      expect(pixel.allows_origin?("not a url")).to be(false)
    end
  end
end
