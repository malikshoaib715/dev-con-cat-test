require "rails_helper"

# The seeds are the demo, so they are held to the same bar as the app: they load
# from the fixtures, they are idempotent, and the credit arithmetic they imply
# is asserted rather than eyeballed.
RSpec.describe "Static seed data" do
  def cost_per_run_for(account)
    as_tenant(account) do
      LayerDefinition.where(key: account.layer_policies.enabled.pluck(:layer_key)).sum(:cost_credits)
    end
  end

  before { load_static_seeds }

  it "loads every canonical layer with its fixture cost" do
    expect(LayerDefinition.count).to eq(10)
    expect(LayerDefinition.ordered.pluck(:key)).to eq(Layers::Registry.keys)
    expect(LayerDefinition.find_by(key: "voice").cost_credits).to eq(5)
    expect(LayerDefinition.find_by(key: "trustedform").cost_credits).to eq(1)
  end

  it "marks the compliance layers as fail-closed and the rest as fail-open" do
    required = LayerDefinition.where(criticality: "required").pluck(:key)

    expect(required).to match_array(%w[trustedform dnc blacklist_alliance duplicate_detection])
  end

  it "charges each account exactly what its purchased module set costs" do
    SeedLoading::COST_PER_RUN.each do |public_id, expected_cost|
      account = Account.find_by!(public_id: public_id)

      expect(cost_per_run_for(account)).to eq(expected_cost)
    end
  end

  it "gives medicare_edge voice but not vpn_proxy, and autoinsure neither" do
    medicare = Account.find_by!(public_id: "acct_medicareedge")
    autoinsure = Account.find_by!(public_id: "acct_autoinsure")

    as_tenant(medicare) do
      expect(medicare.layer_policies.enabled.pluck(:layer_key)).to include("voice")
      expect(medicare.layer_policies.enabled.pluck(:layer_key)).not_to include("vpn_proxy")
    end

    as_tenant(autoinsure) do
      expect(autoinsure.layer_policies.enabled.pluck(:layer_key))
        .to match_array(%w[anura trustedform dnc phone_validation duplicate_detection])
    end
  end

  it "grants the cycle allowance through the ledger, so the balance is always explainable" do
    account = Account.find_by!(public_id: "acct_solarpro")

    as_tenant(account) do
      expect(account.credit_balance).to eq(account.monthly_credit_allowance)
      expect(account.credit_ledger_entries.sum(:amount)).to eq(account.credit_balance)
    end
  end

  it "binds each seeded pixel to the account that captured its leads, and allows localhost for the demo" do
    solar = Account.find_by!(public_id: "acct_solarpro")

    as_tenant(solar) do
      pixel = Pixel.find_by!(public_id: "px_9f2a01")

      expect(pixel.account).to eq(solar)
      expect(pixel.allowed_domains).to include("solar-savings.example.com", "localhost")
      expect(pixel.effective_layer_keys).not_to include("voice")
    end
  end

  it "seeds the users from the fixtures, with exactly one platform operator" do
    expect(User.count).to eq(6)
    expect(User.super_admin.count).to eq(1)
    expect(User.find_by(email: "dana@solarpro.example").valid_password?("ChangeMe!sp1")).to be(true)
  end

  it "is idempotent: running it twice changes nothing" do
    counts = -> {
      ActsAsTenant.without_tenant do
        [ LayerDefinition.count, Account.count, User.count, LayerPolicy.count, Pixel.count,
          CreditLedgerEntry.count ]
      end
    }
    before_counts = counts.call

    load_static_seeds

    expect(counts.call).to eq(before_counts)
  end
end
