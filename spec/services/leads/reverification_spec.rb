require "rails_helper"

RSpec.describe Leads::Reverification do
  before do
    load_static_seeds
    # Every row in this spec belongs to the same buyer, so the tenant is opened
    # once rather than around each assertion.
    ActsAsTenant.current_tenant = account
  end

  let(:account) { fixture_account("acct_solarpro") }
  let(:pixel) { fixture_pixel_for(account) }
  let(:cost_per_run) { SeedLoading::COST_PER_RUN.fetch("acct_solarpro") }

  def held_lead
    create(:lead, account: account, pixel: pixel, status: "on_hold_insufficient_credits")
  end

  describe "a lead held because the account could not pay for it" do
    it "funds a run and starts the layers once the account has topped up" do
      lead = held_lead
      account.update!(credit_balance: cost_per_run)

      result = described_class.call(lead: lead)

      expect(result).to be_success
      expect(lead.reload.status).to eq("verifying")
      expect(lead.verification_run.reserved_credits).to eq(cost_per_run)
      expect(account.reload.credit_balance).to eq(0)
    end

    it "pre-creates a row for every layer, including the ones this account never bought" do
      lead = held_lead
      account.update!(credit_balance: cost_per_run)

      described_class.call(lead: lead)

      results = lead.reload.verification_run.layer_results
      expect(results.count).to eq(Layers::Registry.keys.size)
      expect(results.where(status: "not_enabled").pluck(:layer_key)).to contain_exactly("voice")
    end

    it "records that the verification was started again, so the timeline says why" do
      lead = held_lead
      account.update!(credit_balance: cost_per_run)

      described_class.call(lead: lead)

      event = AuditEvent.for_subject(lead).of_type(Audit::Events::VERIFICATION_STARTED).last
      expect(event.payload["reverified"]).to be(true)
    end

    # A top-up that was not enough must leave the lead exactly as it found it,
    # rather than half-funded or holding an unfunded run.
    it "leaves the lead held, and charges nothing, when the top-up still falls short" do
      lead = held_lead
      account.update!(credit_balance: cost_per_run - 1)

      result = described_class.call(lead: lead)

      expect(result).to be_failure
      expect(result.code).to eq(:insufficient_credits)
      expect(lead.reload.status).to eq("on_hold_insufficient_credits")
      expect(lead.verification_run).to be_nil
      expect(account.reload.credit_balance).to eq(cost_per_run - 1)
    end
  end

  describe "a run that reached the database but never reached the queue" do
    let(:lead) { create(:lead, account: account, pixel: pixel, status: "verifying") }

    let(:stranded_run) do
      run = Verification::RunCreator.call(lead: lead, effective_layer_keys: pixel.effective_layer_keys).value
      # Old enough that nothing is presumed to be working on it any more.
      run.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)
      run
    end

    it "dispatches the layers nobody picked up, without funding a second run" do
      stranded_run
      balance = account.credit_balance

      expect { described_class.call(lead: lead) }
        .to have_enqueued_job(VerificationLayerJob).exactly(pixel.effective_layer_keys.size).times

      expect(lead.reload.verification_run.id).to eq(stranded_run.id)
      expect(account.reload.credit_balance).to eq(balance)
    end
  end

  describe "a lead nobody should be spending credits on again" do
    it "refuses a lead whose verification is under way" do
      lead = create(:lead, account: account, pixel: pixel, status: "verifying")
      Verification::RunCreator.call(lead: lead, effective_layer_keys: [ "anura" ])

      result = described_class.call(lead: lead)

      expect(result).to be_failure
      expect(result.code).to eq(:not_reverifiable)
    end

    it "refuses a lead that has already been decided" do
      lead = create(:lead, account: account, pixel: pixel, status: "completed", verdict: "accept")

      result = described_class.call(lead: lead)

      expect(result.code).to eq(:not_reverifiable)
    end

    it "refuses a held lead whose pixel now runs no layers at all" do
      lead = held_lead
      pixel.update!(enabled_layers: [])

      result = described_class.call(lead: lead)

      expect(result.code).to eq(:no_enabled_layers)
    end
  end
end
