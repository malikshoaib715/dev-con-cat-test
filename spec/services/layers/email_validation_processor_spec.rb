require "rails_helper"

RSpec.describe Layers::EmailValidationProcessor do
  before { load_layer_fixtures(described_class.layer_key) }

  it "belongs to the email_validation layer" do
    expect(described_class.layer_key).to eq("email_validation")
  end

  # L-1008: the domain does not resolve, because it is a homoglyph of one that
  # does. Both providers agree, which is what makes it evidence rather than noise.
  describe "an address both providers say is undeliverable (L-1008)" do
    let(:outcome) { process_fixture_lead("L-1008") }

    it "warns rather than failing hard: a bounced mailbox is not unproven consent" do
      expect(outcome.verdict).to eq("both_undeliverable")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq("2/2 undeliverable")
      expect(outcome.signals).to eq([ "both_undeliverable" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  # L-1002: undeliverable *and* on a throwaway domain. Both signals are emitted,
  # because either alone is a weaker fact than the two together.
  describe "an undeliverable address on a disposable domain (L-1002)" do
    let(:outcome) { process_fixture_lead("L-1002") }

    it "reports both problems" do
      expect(outcome.detail).to eq("2/2 undeliverable, on a disposable domain")
      expect(outcome.signals).to contain_exactly("both_undeliverable", "disposable")
      expect_signals_to_be_weighted(outcome)
    end
  end

  describe "a deliverable address on a disposable domain" do
    let(:outcome) do
      process_payload({
        "providers" => {
          "zerobounce" => { "deliverable" => true, "disposable" => true, "fraud_score" => 70 },
          "neverbounce" => { "deliverable" => true, "disposable" => true, "fraud_score" => 66 }
        }
      })
    end

    it "warns on the domain alone" do
      expect(outcome.verdict).to eq("disposable")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq("2/2 deliverable, but on a disposable domain")
      expect(outcome.signals).to eq([ "disposable" ])
    end
  end

  describe "providers that disagree about deliverability" do
    let(:outcome) do
      process_payload({
        "providers" => {
          "zerobounce" => { "deliverable" => false, "disposable" => false, "fraud_score" => 55 },
          "neverbounce" => { "deliverable" => true, "disposable" => false, "fraud_score" => 20 }
        }
      })
    end

    it "warns and names the dissenter" do
      expect(outcome.verdict).to eq("providers_split")
      expect(outcome.panel_verdict).to eq("warn")
      expect(outcome.detail).to eq(
        "providers disagree — zerobounce says undeliverable, neverbounce says deliverable"
      )
      expect(outcome.signals).to eq([ "providers_split" ])
      expect_signals_to_be_weighted(outcome)
    end
  end

  describe "an address both providers can deliver to (L-1001)" do
    let(:outcome) { process_fixture_lead("L-1001") }

    it "passes with the wording the panel already shows" do
      expect(outcome.verdict).to eq("deliverable")
      expect(outcome.panel_verdict).to eq("pass")
      expect(outcome.detail).to eq("2/2 deliverable")
      expect(outcome.signals).to be_empty
    end
  end

  # An empty payload used to satisfy "nobody said deliverable" and so counted as
  # both providers reporting undeliverable — this layer's heaviest signal, scored
  # against a lead on no evidence at all. The phone layer answers the mirror image
  # of this case the same way.
  it "reports a vendor that returned no providers as a check that did not run" do
    outcome = process_payload({ "providers" => {} })

    expect(outcome.status).to eq("not_applicable")
    expect(outcome.panel_verdict).to eq("skip")
    expect(outcome.detail).to eq("no provider responses")
    expect(outcome.signals).to be_empty
  end

  # A lead reachable by phone may carry keyboard mash where its address should
  # be, and `fghjk@njjj` is accepted by every browser's `type="email"`. The
  # fixture would answer about it like any other identity, so the claim to
  # refuse is "2/2 deliverable" about an address with no domain in it.
  it "reports an address nothing could be delivered to as a check that did not run" do
    account = create(:account)
    lead = as_tenant(account) { create(:lead, account: account, email: "fghjk@njjj") }
    outcome = process_payload(deliverable_payload, lead: lead)

    expect(outcome.status).to eq("not_applicable")
    expect(outcome.panel_verdict).to eq("skip")
    expect(outcome.detail).to eq("no deliverable email address on the lead")
  end

  def deliverable_payload
    {
      "providers" => {
        "zerobounce" => { "status" => "deliverable", "disposable" => false },
        "neverbounce" => { "status" => "deliverable", "disposable" => false }
      }
    }
  end
end
