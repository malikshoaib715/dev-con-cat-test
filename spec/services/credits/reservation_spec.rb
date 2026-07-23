require "rails_helper"

RSpec.describe Credits::Reservation do
  # The service is called from inside the ingestion transaction, with the tenant
  # already established by the pixel key, so specs reproduce both.
  def reserve(account:, run:, layer_keys:)
    as_tenant(account) do
      ApplicationRecord.transaction do
        described_class.call(account: account, run: run, layer_keys: layer_keys)
      end
    end
  end

  def ledger_sum(account)
    as_tenant(account) { account.credit_ledger_entries.sum(:amount) }
  end

  describe "what a run costs" do
    before { load_static_seeds }

    # The fixtures price each layer and each account buys a different set, so the
    # cost of a run is a property of the account, never a flat per-lead fee.
    it "charges each fixture account exactly what its own module set costs" do
      SeedLoading::COST_PER_RUN.each do |public_id, expected_cost|
        account = fixture_account(public_id)

        as_tenant(account) do
          run = create(:verification_run, account: account, reserved_credits: 0)
          layer_keys = account.layer_policies.enabled.pluck(:layer_key)

          expect(reserve(account: account, run: run, layer_keys: layer_keys).value).to eq(expected_cost)
          expect(run.reload.reserved_credits).to eq(expected_cost)
        end
      end
    end

    it "charges nothing for a layer the account did not buy" do
      account = fixture_account("acct_autoinsure")

      as_tenant(account) do
        run = create(:verification_run, account: account, reserved_credits: 0)

        result = reserve(account: account, run: run, layer_keys: %w[anura])

        expect(result.value).to eq(2)
        expect(as_tenant(account) { run.credit_ledger_entries.sole.breakdown }).to eq("anura" => 2)
      end
    end

    # An unpriced layer would silently reserve zero credits and give the check
    # away for free, so drift between the registry and the seeded prices is
    # treated as the bug it is rather than absorbed.
    it "refuses to price a layer that has no definition" do
      account = fixture_account("acct_solarpro")
      as_tenant(account) { LayerDefinition.find_by!(key: "voice").destroy! }
      run = as_tenant(account) { create(:verification_run, account: account) }

      expect { reserve(account: account, run: run, layer_keys: %w[anura voice]) }
        .to raise_error(ArgumentError, /no layer_definition for: voice/)
    end
  end

  describe "a successful reservation" do
    let(:account) { create(:account, credit_balance: 100) }
    let(:run) { as_tenant(account) { create(:verification_run, account: account, reserved_credits: 0) } }

    before do
      load_layer_definitions
      as_tenant(account) { run }
    end

    it "deducts the cost from the balance up front" do
      reserve(account: account, run: run, layer_keys: %w[anura trustedform])

      expect(account.reload.credit_balance).to eq(97)
    end

    it "writes one ledger entry naming what each layer cost" do
      reserve(account: account, run: run, layer_keys: %w[anura trustedform])

      entry = as_tenant(account) { account.credit_ledger_entries.sole }
      expect(entry.entry_type).to eq("reservation")
      expect(entry.amount).to eq(-3)
      expect(entry.balance_after).to eq(97)
      expect(entry.breakdown).to eq("anura" => 2, "trustedform" => 1)
      expect(entry.verification_run_id).to eq(run.id)
      expect(entry.memo).to include(run.lead.public_id)
    end

    # The ledger is the record and the balance is a projection of it, so every
    # entry carries the balance it produced.
    it "snapshots the balance the entry left behind" do
      reserve(account: account, run: run, layer_keys: %w[anura trustedform])

      entry = as_tenant(account) { account.credit_ledger_entries.sole }
      expect(entry.balance_after).to eq(account.reload.credit_balance)
      expect(entry.amount).to eq(account.credit_balance - 100)
    end

    it "records the reservation on the audit spine against the lead" do
      reserve(account: account, run: run, layer_keys: %w[anura trustedform])

      event = as_tenant(account) { AuditEvent.of_type(Audit::Events::CREDITS_RESERVED).sole }
      expect(event.subject_id).to eq(run.lead_id)
      expect(event.payload).to include("total" => 3, "balance_after" => 97,
                                       "breakdown" => { "anura" => 2, "trustedform" => 1 })
    end

    it "lets an account spend its last credit" do
      account.update!(credit_balance: 3)

      result = reserve(account: account, run: run, layer_keys: %w[anura trustedform])

      expect(result).to be_success
      expect(account.reload.credit_balance).to eq(0)
    end
  end

  describe "when the account cannot afford the run" do
    let(:account) { create(:account, credit_balance: 2) }
    let(:run) { as_tenant(account) { create(:verification_run, account: account, reserved_credits: 0) } }
    let(:result) { reserve(account: account, run: run, layer_keys: %w[anura trustedform]) }

    before do
      load_layer_definitions
      as_tenant(account) { run }
    end

    # A domain outcome, not an exception: the caller has to keep the lead and mark
    # it held, which means the transaction must be allowed to commit.
    it "fails with a code the caller can act on rather than raising" do
      expect(result).to be_failure
      expect(result.code).to eq(:insufficient_credits)
      expect(result.error.first).to include("costs 3 and the balance is 2")
    end

    it "spends nothing" do
      result

      expect(account.reload.credit_balance).to eq(2)
      expect(as_tenant(account) { account.credit_ledger_entries.count }).to eq(0)
      expect(run.reload.reserved_credits).to eq(0)
    end

    it "records why the run never started" do
      result

      event = as_tenant(account) { AuditEvent.of_type(Audit::Events::CREDITS_INSUFFICIENT).sole }
      expect(event.payload).to include("required" => 3, "available" => 2)
    end
  end

  # Without this tag RSpec's own wrapping transaction would satisfy the guard and
  # the example would prove nothing.
  describe "misuse", :real_transactions do
    # The deduction, the ledger row, and the run it funds have to commit or fail
    # together; committing on its own could debit an account for a run that never
    # existed.
    it "refuses to run outside a transaction" do
      account = create(:account)
      load_layer_definitions
      run = as_tenant(account) { create(:verification_run, account: account) }

      expect { as_tenant(account) { described_class.call(account: account, run: run, layer_keys: %w[anura]) } }
        .to raise_error(ArgumentError, /inside a transaction/)
    end
  end

  describe "concurrent submissions", :real_transactions do
    # Two leads arriving at once against a balance that only funds one. The row
    # lock is what decides it; without it both would read the same balance and
    # both would be funded.
    it "funds exactly one and leaves the ledger consistent with the balance" do
      load_layer_definitions
      account = create(:account, credit_balance: 3)
      runs = as_tenant(account) { Array.new(2) { create(:verification_run, account: account, reserved_credits: 0) } }

      results = in_parallel(2, tenant: account) do |index|
        reserve(account: Account.find(account.id), run: runs[index], layer_keys: %w[anura trustedform])
      end

      expect(results.count(&:success?)).to eq(1)
      expect(account.reload.credit_balance).to eq(0)
      expect(as_tenant(account) { account.credit_ledger_entries.count }).to eq(1)
      expect(ledger_sum(account)).to eq(-3)
    end
  end
end
