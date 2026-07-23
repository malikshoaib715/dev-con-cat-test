require "rails_helper"

RSpec.describe Layers::VpnProxyProcessor do
  before { load_layer_fixtures(described_class.layer_key) }

  it "belongs to the vpn_proxy layer" do
    expect(described_class.layer_key).to eq("vpn_proxy")
  end

  # L-1003: browsed from a residential address, submitted through a commercial
  # VPN. The mismatch is the masking pattern and is weighted on top of the VPN.
  describe "a commercial VPN masking a residential visit (L-1003)" do
    let(:outcome) { process_fixture_lead("L-1003") }

    it "fails the layer and names both the VPN and the mismatch" do
      expect(outcome.status).to eq("completed")
      expect(outcome.verdict).to eq("anonymizing_network")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to eq("VPN and datacenter IP detected; visit IP ≠ submit IP")
    end

    it "emits both weighted signals" do
      expect(outcome.signals).to contain_exactly("anonymizing_network", "visit_ip_mismatch")
      expect_signals_to_be_weighted(outcome)
    end
  end

  # L-1002: Tor exit plus datacenter ASN, the bot's own address.
  describe "a Tor exit node in a datacenter (L-1002)" do
    let(:outcome) { process_fixture_lead("L-1002") }

    it "names every kind of anonymizer the vendor found" do
      expect(outcome.detail).to eq("proxy, Tor exit node, and datacenter IP detected; visit IP ≠ submit IP")
      expect(outcome.panel_verdict).to eq("fail")
    end
  end

  # L-1007: nothing detected, but the vendor is uneasy about the device.
  describe "a clean IP the vendor is still uneasy about (L-1007)" do
    let(:outcome) { process_fixture_lead("L-1007") }

    it "warns rather than fails, and weights it lightly" do
      expect(outcome.verdict).to eq("risk_medium")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq("residential IP, elevated risk")
      expect(outcome.signals).to eq([ "risk_medium" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  describe "a residential IP that browsed and submitted from the same place (L-1001)" do
    let(:outcome) { process_fixture_lead("L-1001") }

    it "passes with nothing to score" do
      expect(outcome.verdict).to eq("clean")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to eq("residential IP, submit matches visit")
      expect(outcome.signals).to be_empty
    end
  end

  # An anonymizer used consistently is weaker evidence than one that appeared
  # only at submission time.
  describe "an anonymizer with no mismatch" do
    let(:outcome) do
      process_payload({
        "is_vpn" => true, "is_proxy" => false, "is_tor" => false, "is_datacenter" => false,
        "site_visit_ip_matches_submit_ip" => true, "risk" => "high"
      })
    end

    it "reports the VPN without the mismatch signal" do
      expect(outcome.detail).to eq("VPN detected")
      expect(outcome.signals).to eq([ "anonymizing_network" ])
    end
  end

  it "keeps the vendor's answer for the certificate" do
    expect(process_fixture_lead("L-1003").raw_response).to include("is_vpn" => true, "risk" => "high")
  end
end
