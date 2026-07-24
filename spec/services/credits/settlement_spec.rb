require "rails_helper"

RSpec.describe Credits::Settlement do
  before { load_static_seeds }

  # A run funded the way ingestion funds one, so the refund is priced off a real
  # reservation rather than a hand-written ledger row.
  def funded_run(public_id, layer_states: {}, layer_keys: nil)
    account = fixture_account(public_id)

    as_tenant(account) do
      lead = create(:lead, account: account)
      layer_keys ||= account.layer_policies.enabled.pluck(:layer_key)
      run = Verification::RunCreator.call(lead: lead, effective_layer_keys: layer_keys).value
      ApplicationRecord.transaction do
        Credits::Reservation.call(account: account, run: run, layer_keys: layer_keys)
      end

      complete_layers(run, layer_states)
      run
    end
  end

  # Whatever the vendors said, minus the states this spec is actually about.
  def complete_layers(run, layer_states)
    run.layer_results.outstanding.find_each do |row|
      row.update!(status: layer_states.fetch(row.layer_key, "completed"), completed_at: Time.current)
    end
  end

  def settle(run)
    as_tenant(run.account) { described_class.call(run: run) }
  end

  def audit_count(event_type)
    ActsAsTenant.without_tenant { AuditEvent.where(event_type: event_type).count }
  end

  def ledger_sum(account)
    as_tenant(account) { account.credit_ledger_entries.sum(:amount) }
  end

  describe "what comes back" do
    it "refunds a layer that had nothing to judge" do
      run = funded_run("acct_medicareedge", layer_states: { "voice" => "not_applicable" })

      result = settle(run)

      expect(result.value).to eq(5)
      expect(run.reload.settled_credits).to eq(16)
      expect(run.account.reload.credit_balance).to eq(fixture_account("acct_medicareedge").credit_balance)
    end

    it "refunds a layer that could not answer" do
      run = funded_run("acct_solarpro", layer_states: { "enrichment" => "errored" })

      expect(settle(run).value).to eq(4)
      expect(run.reload.settled_credits).to eq(13)
    end

    it "refunds every unrun layer together, priced from what was charged" do
      run = funded_run("acct_medicareedge",
                       layer_states: { "voice" => "not_applicable", "enrichment" => "errored" })

      expect(settle(run).value).to eq(9)
      expect(as_tenant(run.account) { run.credit_ledger_entries.entry_type_settlement_refund.sole.breakdown })
        .to eq("voice" => 5, "enrichment" => 4)
    end

    it "refunds nothing when every layer answered, and still records that it settled" do
      run = funded_run("acct_autoinsure")

      expect(settle(run).value).to eq(0)

      entry = as_tenant(run.account) { run.credit_ledger_entries.entry_type_settlement_refund.sole }
      expect(entry.amount).to eq(0)
      expect(run.reload.settled_credits).to eq(8)
    end

    it "charges nothing for a layer the account never bought" do
      run = funded_run("acct_autoinsure")
      as_tenant(run.account) { expect(run.layer_results.where(status: "not_enabled")).to be_any }

      expect(settle(run).value).to eq(0)
    end

    # Costs are policy and policy changes. What an account was charged is history,
    # and a refund priced from today's numbers would return credits that were
    # never taken.
    it "ignores a price change made after the run was funded" do
      run = funded_run("acct_medicareedge", layer_states: { "voice" => "not_applicable" })
      LayerDefinition.find_by!(key: "voice").update!(cost_credits: 500)

      expect(settle(run).value).to eq(5)
    end
  end

  describe "being called twice" do
    it "refunds once and leaves one entry behind" do
      run = funded_run("acct_medicareedge", layer_states: { "voice" => "not_applicable" })

      settle(run)
      balance = run.account.reload.credit_balance

      expect(settle(run).value).to eq(0)
      expect(run.account.reload.credit_balance).to eq(balance)
      expect(as_tenant(run.account) { run.credit_ledger_entries.entry_type_settlement_refund.count }).to eq(1)
    end
  end

  describe "two settlements racing the same run", :real_transactions do
    # Both may pass the already-settled check before either commits; the unique
    # (verification_run_id, entry_type) index arbitrates, the loser's transaction
    # rolls back — including its balance update — and it reports a no-op.
    it "refunds once and keeps the balance equal to the ledger" do
      load_static_seeds
      run = funded_run("acct_medicareedge", layer_states: { "voice" => "not_applicable" })

      results = in_parallel(2, tenant: run.account) { described_class.call(run: run) }

      expect(results.map(&:success?)).to all(be(true))
      as_tenant(run.account) do
        expect(run.credit_ledger_entries.entry_type_settlement_refund.count).to eq(1)
        expect(run.account.reload.credit_balance).to eq(run.account.credit_ledger_entries.sum(:amount))
      end
    end
  end

  describe "the ledger invariant" do
    it "keeps the balance equal to the sum of the ledger" do
      run = funded_run("acct_solarpro", layer_states: { "enrichment" => "errored" })
      settle(run)

      expect(run.account.reload.credit_balance).to eq(ledger_sum(run.account))
    end
  end

  describe "the low-credit warning" do
    # AutoInsure is the fixture account that runs dry: 80 credits against a burn
    # of 410 a day is well under a day of runway.
    it "records a flag when a run takes the account under the threshold" do
      run = funded_run("acct_autoinsure")
      # Eight credits spent this week is a burn of about 1.14 a day, so three
      # credits left is under two days of runway and this run is what took it there.
      as_tenant(run.account) { run.account.update!(credit_balance: 3) }

      expect { settle(run) }.to change { audit_count(Audit::Events::ACCOUNT_FLAGGED_LOW_CREDITS) }.by(1)
    end

    it "does not flag an account with plenty of runway" do
      run = funded_run("acct_medicareedge", layer_states: { "voice" => "not_applicable" })

      expect { settle(run) }.not_to change { audit_count(Audit::Events::ACCOUNT_FLAGGED_LOW_CREDITS) }
    end

    it "flags the crossing once rather than on every later run" do
      first = funded_run("acct_autoinsure")
      as_tenant(first.account) { first.account.update!(credit_balance: 3) }
      settle(first)
      second = funded_run("acct_autoinsure", layer_keys: %w[dnc])

      expect { settle(second) }.not_to change { audit_count(Audit::Events::ACCOUNT_FLAGGED_LOW_CREDITS) }
    end
  end

  it "audits what it returned" do
    run = funded_run("acct_medicareedge", layer_states: { "voice" => "not_applicable" })
    settle(run)

    event = ActsAsTenant.without_tenant { AuditEvent.where(event_type: Audit::Events::CREDITS_SETTLED).last }
    expect(event.payload).to include("refunded" => 5, "spent" => 16)
    expect(event.subject_id).to eq(run.lead.id)
  end
end
