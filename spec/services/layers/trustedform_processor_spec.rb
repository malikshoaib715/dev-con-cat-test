require "rails_helper"

RSpec.describe Layers::TrustedformProcessor do
  before { load_layer_fixtures(described_class.layer_key) }

  it "belongs to the trustedform layer" do
    expect(described_class.layer_key).to eq("trustedform")
  end

  describe "a certificate that proves consent (L-1001)" do
    let(:outcome) { process_fixture_lead("L-1001") }

    it "passes with the wording the panel already shows" do
      expect(outcome.verdict).to eq("verified")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to eq("cert verified, phone+email match")
      expect(outcome.signals).to be_empty
    end
  end

  # L-1010: the certificate's phone is somebody else's, its page fingerprint
  # points at an unrelated offer page, it carries no consent language, and its
  # window closed six weeks before the lead was captured.
  describe "a certificate that proves nothing (L-1010)" do
    let(:outcome) { process_fixture_lead("L-1010") }

    it "fails the layer" do
      expect(outcome.verdict).to eq("mismatch")
      expect(outcome.panel_verdict).to eq("fail")
    end

    it "names every part of the proof that failed, not just the status" do
      expect(outcome.detail).to start_with("consent cannot be proven (mismatch):")
      expect(outcome.detail).to include("certificate phone does not match the lead")
      expect(outcome.detail).to include("page fingerprint differs from the landing page")
      expect(outcome.detail).to include("no consent language was present")
      expect(outcome.detail).to include("the certificate expired")
    end

    # Unprovable consent is a hard stop matched on the verdict string, so there is
    # no score to contribute to.
    it "emits no weighted signal" do
      expect(outcome.signals).to be_empty
    end
  end

  describe "a certificate that was never retained" do
    let(:outcome) do
      process_payload({ "status" => "not_found", "matches_phone" => nil, "matches_email" => nil })
    end

    it "says so plainly rather than listing discrepancies it cannot see" do
      expect(outcome.verdict).to eq("not_found")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to eq("consent cannot be proven (not_found): no certificate was retained for this lead")
    end
  end

  describe "a certificate whose window has closed" do
    let(:outcome) do
      process_payload({
        "status" => "expired", "matches_phone" => true, "matches_email" => true,
        "consent_language_present" => true, "expires_at" => "2020-01-01T00:00:00Z"
      })
    end

    it "reports the expiry it observed" do
      expect(outcome.verdict).to eq("expired")
      expect(outcome.detail).to include("the certificate expired 2020-01-01T00:00:00Z")
    end
  end

  # The clean default has no page or expiry recorded, and a lead nobody has an
  # opinion about must not be failed for fields the vendor never returned.
  describe "an unknown lead falling through to the clean default" do
    let(:outcome) do
      account = create(:account)
      lead = as_tenant(account) { create(:lead, account: account, email_normalized: "nobody@example.com") }
      as_tenant(account) { described_class.call(lead: lead) }
    end

    it "verifies rather than inventing a discrepancy" do
      expect(outcome.verdict).to eq("verified")
      expect(outcome.panel_verdict).to eq("pass")
    end
  end
end
