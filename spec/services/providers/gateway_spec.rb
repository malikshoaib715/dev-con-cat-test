require "rails_helper"

RSpec.describe Providers::Gateway do
  describe "tier 1: the seeded lead's own response" do
    before do
      load_static_seeds
      load_provider_responses
    end

    it "returns the fixture recorded against that lead id" do
      lead = fixture_lead("L-1005")

      payload = described_class.fetch(layer_key: "dnc", lead: lead)

      expect(payload).to include("dnc_status" => "dnc_listed", "national_dnc" => true)
    end

    it "answers every vendor layer for every fixture lead" do
      lead = fixture_lead("L-1009")

      Seeds::ProviderResponses::VENDOR_LAYER_KEYS.each do |layer_key|
        expect(described_class.fetch(layer_key: layer_key, lead: lead)).to be_present
      end
    end

    it "keeps the documentation out of the payload" do
      lead = fixture_lead("L-1008")

      payload = described_class.fetch(layer_key: "email_validation", lead: lead)

      expect(payload.fetch("providers").keys).to contain_exactly("zerobounce", "neverbounce")
    end
  end

  describe "tier 2: a lead the gateway has never seen, with a known identity" do
    before do
      load_static_seeds
      load_provider_responses
    end

    # This is the demo: type Robert Vance's number into the live form and his DNC
    # hard stop plays out for real, through the whole pipeline.
    it "replays a persona's scenario for a lead matched on phone alone" do
      walk_in = fixture_lead("L-1005", public_id: "L-9001", email: "someone.else@example.com",
                                       email_normalized: "someone.else@example.com")

      payload = described_class.fetch(layer_key: "dnc", lead: walk_in)

      expect(payload).to include("dnc_status" => "dnc_listed")
    end

    it "replays a persona's scenario for a lead matched on email alone" do
      walk_in = fixture_lead("L-1008", public_id: "L-9002", phone: "+19998887777",
                                       phone_normalized: "+19998887777")

      payload = described_class.fetch(layer_key: "email_validation", lead: walk_in)

      expect(payload.dig("providers", "zerobounce", "deliverable")).to be(false)
    end

    # A lead's own recorded response is the more specific answer and has to win,
    # or a shared identity would overwrite it.
    it "prefers the lead's own response over an identity match" do
      lead = fixture_lead("L-1001")
      as_tenant(lead.account) do
        ProviderResponse.create!(layer_key: "dnc", lead_ref: "L-0001",
                                 phone_normalized: lead.phone_normalized,
                                 payload: { "dnc_status" => "internal_dnc" })
      end

      payload = described_class.fetch(layer_key: "dnc", lead: lead)

      expect(payload).to include("dnc_status" => "callable")
    end
  end

  describe "tier 3: an identity nobody has an opinion about" do
    before { load_layer_definitions }

    let(:stranger) do
      account = create(:account)
      as_tenant(account) do
        create(:lead, account: account, public_id: "L-9100",
                      email: "brand.new@example.com", email_normalized: "brand.new@example.com",
                      phone: "+12125551234", phone_normalized: "+12125551234")
      end
    end

    # Erroring on an unknown identity would mean every live demonstration opens
    # with ten failures. An unknown lead is not a suspicious one.
    it "answers every vendor layer with a clean default" do
      Seeds::ProviderResponses::VENDOR_LAYER_KEYS.each do |layer_key|
        expect(described_class.fetch(layer_key: layer_key, lead: stranger))
          .to eq(described_class::CLEAN_DEFAULTS.fetch(layer_key))
      end
    end

    it "has a default for every vendor-backed layer in the registry" do
      expect(described_class::CLEAN_DEFAULTS.keys)
        .to match_array(Layers::Registry.keys - %w[duplicate_detection])
    end

    it "hands out a copy, so one caller cannot mutate the default for the next" do
      payload = described_class.fetch(layer_key: "anura", lead: stranger)
      payload["result"] = "bad"

      expect(described_class.fetch(layer_key: "anura", lead: stranger)).to include("result" => "good")
    end

    it "gives a lead with no identity at all the clean default rather than raising" do
      account = create(:account)
      anonymous = as_tenant(account) do
        create(:lead, account: account, email: nil, email_normalized: nil,
                      phone: "+15005550000", phone_normalized: nil)
      end

      expect(described_class.fetch(layer_key: "vpn_proxy", lead: anonymous)).to include("risk" => "low")
    end
  end

  describe "layers with no vendor behind them" do
    let(:lead) do
      account = create(:account)
      as_tenant(account) { create(:lead, account: account) }
    end

    # Duplicate detection is answered from the buyer's own CRM. Asking the gateway
    # for it is a wiring mistake and says so immediately.
    it "refuses to be asked about duplicate detection" do
      expect { described_class.fetch(layer_key: "duplicate_detection", lead: lead) }
        .to raise_error(ArgumentError, /no provider for layer/)
    end

    it "refuses an unknown layer key" do
      expect { described_class.fetch(layer_key: "trusted_form", lead: lead) }
        .to raise_error(ArgumentError, /no provider for layer/)
    end
  end

  describe "simulated latency" do
    let(:lead) do
      account = create(:account)
      as_tenant(account) { create(:lead, account: account) }
    end

    it "never sleeps in the suite, which would otherwise spend its life waiting" do
      gateway = described_class.new(layer_key: "voice", lead: lead)
      allow(gateway).to receive(:sleep)

      gateway.fetch

      expect(gateway).not_to have_received(:sleep)
    end

    it "is priced per layer, so the panel trickles the same way every time" do
      expect(described_class::LATENCY_MS.keys)
        .to match_array(Layers::Registry.keys - %w[duplicate_detection])
      expect(described_class::LATENCY_MS.values).to all(be_between(250, 900))
    end

    it "pays the latency when the environment asks for it" do
      allow(Rails.application.config.x.providers).to receive(:simulated_latency).and_return(true)
      gateway = described_class.new(layer_key: "voice", lead: lead)
      allow(gateway).to receive(:sleep)

      gateway.fetch

      expect(gateway).to have_received(:sleep).with(0.9)
    end
  end
end
