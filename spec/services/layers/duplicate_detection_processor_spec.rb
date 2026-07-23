require "rails_helper"

RSpec.describe Layers::DuplicateDetectionProcessor do
  before do
    load_layer_fixtures(described_class.layer_key)
    load_crm_records
  end

  it "belongs to the duplicate_detection layer" do
    expect(described_class.layer_key).to eq("duplicate_detection")
  end

  # The only layer with no vendor behind it, so it must not reach for one.
  it "never calls the provider gateway" do
    expect(Providers::Gateway).not_to receive(:fetch)

    process_fixture_lead("L-1001")
  end

  # L-1004 is the same person as ME-88213 in acct_medicareedge's own CRM: same
  # phone and same email. The buyer must not pay for her twice.
  describe "a person already in the buyer's CRM (L-1004)" do
    let(:outcome) { process_fixture_lead("L-1004") }

    it "fails the layer and cites the record" do
      expect(outcome.verdict).to eq("exact_duplicate")
      expect(outcome.panel_verdict).to eq("fail")
      expect(outcome.detail).to start_with("already in CRM as ME-88213")
    end

    # A hard stop, so there is no score for it to contribute to.
    it "emits no weighted signal" do
      expect(outcome.signals).to be_empty
    end

    it "keeps what it found in the CRM as evidence, since there is no vendor payload" do
      expect(outcome.raw_response.fetch("crm_matches").first)
        .to include("external_ref" => "ME-88213", "matched_on" => %w[phone email])
    end
  end

  # L-1012: the same phone as AI-55019 with a different email, hours apart. More
  # likely a returning customer than a fraud, and that is a human's call — auto
  # rejecting it would throw away a good lead.
  describe "the same phone with a different email (L-1012)" do
    let(:outcome) { process_fixture_lead("L-1012") }

    it "warns instead of rejecting, and says why a human should look" do
      expect(outcome.verdict).to eq("soft_duplicate")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to include("same phone as AI-55019")
      expect(outcome.detail).to include("different email")
      expect(outcome.detail).to include("possible returning customer")
    end

    it "is weighted rather than fatal" do
      expect(outcome.signals).to eq([ "soft_duplicate" ])
      expect_signals_to_be_weighted(outcome)
    end

    # That fixture's CRM record is dated a few hours *after* the lead was captured,
    # which is what a CRM export taken later looks like. Only counting elapsed time
    # would miss it entirely.
    it "measures the window as an absolute difference, so a later CRM export still matches" do
      account = fixture_account("acct_autoinsure")
      crm_record = as_tenant(account) { CrmRecord.find_by!(external_ref: "AI-55019") }
      captured_at = Time.utc(2026, 7, 14, 16, 1, 20)

      expect(crm_record.source_created_at).to be > captured_at
      expect(outcome.verdict).to eq("soft_duplicate")
    end
  end

  describe "a partial match from long ago" do
    let(:outcome) do
      account = fixture_account("acct_autoinsure")
      as_tenant(account) do
        CrmRecord.find_by!(external_ref: "AI-55019").update!(source_created_at: 8.months.before(Time.utc(2026, 7, 14)))
      end

      process_fixture_lead("L-1012")
    end

    # An old enquiry from the same number is a different enquiry.
    it "passes, but says the record exists rather than claiming no match" do
      expect(outcome.verdict).to eq("no_match")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to start_with("no recent CRM match — AI-55019 shares this lead's phone")
      expect(outcome.signals).to be_empty
    end
  end

  describe "a lead nobody in the CRM resembles (L-1001)" do
    let(:outcome) { process_fixture_lead("L-1001") }

    it "passes with the wording the panel already shows" do
      expect(outcome.verdict).to eq("no_match")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to eq("no CRM match for account")
      expect(outcome.signals).to be_empty
    end
  end

  # The same person in two buyers' CRMs is two legitimate leads. Matching across
  # accounts would let one buyer's history reject another buyer's lead.
  describe "tenancy" do
    it "never matches against another account's CRM" do
      medicare_duplicate = fixture_account("acct_medicareedge")
      solar_lead = fixture_lead("L-1004", account: fixture_account("acct_solarpro"), public_id: "L-9004")

      outcome = as_tenant(fixture_account("acct_solarpro")) { described_class.call(lead: solar_lead) }

      expect(as_tenant(medicare_duplicate) { CrmRecord.find_by(external_ref: "ME-88213") }).to be_present
      expect(outcome.verdict).to eq("no_match")
    end
  end
end
