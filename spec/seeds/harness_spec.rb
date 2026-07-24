require "rails_helper"

# The regression net for the whole build: twelve fixture leads ingested through
# the real service, verified by the real pipeline, and judged by the real engine.
# Nothing is stubbed and no expected verdict is ever handed to the application —
# the fixtures' hints are read back out of the file here and compared.
#
# If a row in this spec fails, the weights in db/seeds/layer_definitions.rb are
# wrong. The engine is not the place to fix it.
FIXTURE_VERDICTS = {
    "L-1001" => { verdict: "accept", score: 100, hard_stop: nil,                   flags: [] },
    "L-1002" => { verdict: "reject", score: 0,   hard_stop: "anura",               flags: [] },
    "L-1003" => { verdict: "review", score: 65,  hard_stop: nil,                   flags: [] },
    "L-1004" => { verdict: "reject", score: 0,   hard_stop: "duplicate_detection", flags: [ "duplicate" ] },
    "L-1005" => { verdict: "reject", score: 0,   hard_stop: "dnc",                 flags: [] },
    "L-1006" => { verdict: "reject", score: 0,   hard_stop: "dnc",                 flags: [] },
    "L-1007" => { verdict: "review", score: 60,  hard_stop: nil,                   flags: [] },
    "L-1008" => { verdict: "review", score: 65,  hard_stop: nil,                   flags: [] },
    "L-1009" => { verdict: "reject", score: 35,  hard_stop: nil,                   flags: [] },
    "L-1010" => { verdict: "reject", score: 0,   hard_stop: "trustedform",         flags: [] },
    "L-1011" => { verdict: "review", score: 58,  hard_stop: nil,                   flags: [] },
    "L-1012" => { verdict: "accept", score: 90,  hard_stop: nil,                   flags: [ "soft_duplicate" ] }
}.freeze

RSpec.describe "the twelve fixture leads", :seeded_world do
  def lead(lead_ref)
    ActsAsTenant.without_tenant { Lead.find_by!(public_id: lead_ref) }
  end

  def verdict_for(lead_ref)
    found = lead(lead_ref)
    ActsAsTenant.with_tenant(found.account) { found.verification_run.consensus_verdict }
  end

  FIXTURE_VERDICTS.each do |lead_ref, expected|
    it "derives #{expected[:verdict]} at #{expected[:score]} for #{lead_ref}" do
      verdict = verdict_for(lead_ref)

      expect(verdict.verdict).to eq(expected[:verdict])
      expect(verdict.score).to eq(expected[:score])
      expect(verdict.hard_stop_layer).to eq(expected[:hard_stop])
      expect(verdict.flags).to eq(expected[:flags])
      expect(lead(lead_ref).verdict).to eq(expected[:verdict])
    end
  end

  it "matches every hint in the fixture file" do
    rows = Seeds::Leads.report

    expect(rows.size).to eq(12)
    expect(rows.reject(&:matches?)).to be_empty
  end

  # AutoInsure does not pay for the litigator layer, so the only thing that can
  # refuse this lead is the DNC listing. Getting the right answer from the wrong
  # layer would mean the engine was scoring checks the buyer never bought.
  it "refuses L-1005 through DNC, the only compliance layer AutoInsure owns" do
    verdict = verdict_for("L-1005")
    row = ActsAsTenant.without_tenant do
      LayerResult.find_by!(verification_run_id: lead("L-1005").verification_run.id,
                           layer_key: "blacklist_alliance")
    end

    expect(verdict.hard_stop_layer).to eq("dnc")
    expect(row.status).to eq("not_enabled")
  end

  it "rejects L-1004 as a duplicate and names the CRM record it matched" do
    verdict = verdict_for("L-1004")

    expect(verdict.hard_stop_layer).to eq("duplicate_detection")
    expect(verdict.reasons.first).to include("ME-88213")
  end

  # A returning customer, not a fraud: flagged for a human and still bought.
  it "keeps L-1012 accepted while flagging the soft duplicate" do
    verdict = verdict_for("L-1012")

    expect(verdict.verdict).to eq("accept")
    expect(verdict.flags).to eq([ "soft_duplicate" ])
    expect(verdict.reasons.first).to include("AI-55019")
  end

  it "never scores a layer the account did not buy" do
    ActsAsTenant.without_tenant do
      expect(LayerResult.where(status: "not_enabled").where.not(score_delta: nil)).to be_empty
    end
  end

  describe "the money" do
    it "lands each account on the balance in accounts.json" do
      expected = Seeds::MockData.read("accounts.json").fetch("accounts")
                                .to_h { |account| [ account.fetch("account_id"), account.fetch("credits_remaining") ] }

      ActsAsTenant.without_tenant do
        expect(Account.pluck(:public_id, :credit_balance).to_h).to eq(expected)
      end
    end

    it "keeps every balance equal to the sum of its own ledger" do
      ActsAsTenant.without_tenant { Account.all.to_a }.each do |account|
        ledger = ActsAsTenant.with_tenant(account) { account.credit_ledger_entries.sum(:amount) }

        expect(ledger).to eq(account.credit_balance), "#{account.public_id} does not reconcile"
      end
    end

    it "charges each run what that account's own module set costs" do
      SeedLoading::COST_PER_RUN.each do |public_id, cost|
        account = ActsAsTenant.without_tenant { Account.find_by!(public_id: public_id) }
        reserved = ActsAsTenant.with_tenant(account) { account.verification_runs.pluck(:reserved_credits).uniq }

        expect(reserved).to eq([ cost ])
      end
    end
  end

  describe "the certificates" do
    it "issues one per run, and every one of them verifies" do
      ActsAsTenant.without_tenant { Account.all.to_a }.each do |account|
        ActsAsTenant.with_tenant(account) do
          certificates = account.consent_certificates.chain_order.to_a

          expect(certificates.size).to eq(account.verification_runs.count)
          certificates.each do |certificate|
            expect(Certificates::Verifier.call(certificate: certificate)).to be_valid
          end
        end
      end
    end

    it "numbers each account's chain from one, without gaps" do
      ActsAsTenant.without_tenant { Account.all.to_a }.each do |account|
        sequence = ActsAsTenant.with_tenant(account) do
          account.consent_certificates.chain_order.pluck(:sequence_number)
        end

        expect(sequence).to eq((1..sequence.size).to_a)
      end
    end

    it "records all ten layers on every certificate" do
      ActsAsTenant.without_tenant { ConsentCertificate.all.to_a }.each do |certificate|
        expect(certificate.evidence["layers"].keys).to match_array(Layers::Registry.keys)
      end
    end
  end

  describe "the buyers' CRMs" do
    it "gains exactly the accepted leads" do
      ActsAsTenant.without_tenant do
        expect(CrmRecord.where(external_ref: %w[L-1001 L-1012]).count).to eq(2)
        expect(CrmRecord.where(external_ref: %w[L-1002 L-1004 L-1005 L-1011])).to be_empty
      end
    end
  end

  describe "the audit trail" do
    it "reads from receipt to settlement for a seeded lead" do
      found = lead("L-1001")
      types = ActsAsTenant.without_tenant do
        AuditEvent.where(session_id: "seed-L-1001").order(:id).pluck(:event_type)
      end

      expect(found.status).to eq("completed")
      expect(types.first(4)).to eq([
        Audit::Events::PIXEL_VISIT_RECORDED,
        Audit::Events::LEAD_RECEIVED,
        Audit::Events::CREDITS_RESERVED,
        Audit::Events::VERIFICATION_STARTED
      ])
      expect(types.last(4)).to eq([
        Audit::Events::CONSENSUS_EVALUATED,
        Audit::Events::VERDICT_ISSUED,
        Audit::Events::CERTIFICATE_ISSUED,
        Audit::Events::CREDITS_SETTLED
      ])
      expect(types).to include(Audit::Events::LAYER_COMPLETED)
    end
  end

  it "is idempotent: re-seeding changes nothing" do
    counts = ActsAsTenant.without_tenant do
      { leads: Lead.count, runs: VerificationRun.count, certificates: ConsentCertificate.count,
        ledger: CreditLedgerEntry.count, crm: CrmRecord.count,
        balances: Account.pluck(:public_id, :credit_balance).to_h }
    end

    load_all_seeds

    expect(ActsAsTenant.without_tenant do
      { leads: Lead.count, runs: VerificationRun.count, certificates: ConsentCertificate.count,
        ledger: CreditLedgerEntry.count, crm: CrmRecord.count,
        balances: Account.pluck(:public_id, :credit_balance).to_h }
    end).to eq(counts)
  end
end
