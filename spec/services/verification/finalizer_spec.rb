require "rails_helper"

RSpec.describe Verification::Finalizer do
  before { load_static_seeds }

  # A run in exactly the state the completion gate hands over: funded, every layer
  # terminal, claimed for finalization.
  def claimed_run(public_id = "acct_solarpro", layer_states: {}, verdicts: {}, **lead_attributes)
    account = fixture_account(public_id)

    as_tenant(account) do
      lead = create(:lead, account: account, **lead_attributes)
      layer_keys = account.layer_policies.enabled.pluck(:layer_key)
      run = Verification::RunCreator.call(lead: lead, effective_layer_keys: layer_keys).value
      ApplicationRecord.transaction do
        Credits::Reservation.call(account: account, run: run, layer_keys: layer_keys)
      end

      finish_layers(run, layer_states, verdicts)
      run.update!(status: "finalizing")
      run
    end
  end

  def finish_layers(run, layer_states, verdicts)
    run.layer_results.outstanding.find_each do |row|
      row.update!(status: layer_states.fetch(row.layer_key, "completed"),
                  verdict: verdicts.fetch(row.layer_key, "clean"),
                  panel_verdict: "pass", detail: "#{row.layer_key} answered",
                  raw_response: { "signals" => Array(signals_for(row, verdicts)) },
                  completed_at: Time.current)
    end
  end

  def signals_for(row, verdicts)
    verdicts.key?(row.layer_key) ? [ verdicts.fetch(row.layer_key) ] : []
  end

  def finalize(run)
    as_tenant(run.account) { described_class.call(run: run) }
  end

  def audit_types(lead)
    ActsAsTenant.without_tenant do
      AuditEvent.where(subject_type: "Lead", subject_id: lead.id).order(:id).pluck(:event_type)
    end
  end

  describe "a clean run" do
    let(:run) { claimed_run }

    before { finalize(run) }

    it "records the verdict with the policy that produced it" do
      verdict = as_tenant(run.account) { run.reload.consensus_verdict }

      expect(verdict.verdict).to eq("accept")
      expect(verdict.score).to eq(100)
      expect(verdict.reasons).to eq([ "all enabled layers passed" ])
      expect(verdict.policy_snapshot["thresholds"]).to eq("accept" => 70, "review" => 40)
    end

    it "closes the run" do
      expect(run.reload.status).to eq("completed")
      expect(run.completed_at).to be_present
    end

    it "denormalizes the answer onto the lead the dashboard lists" do
      lead = run.lead.reload

      expect(lead.status).to eq("completed")
      expect(lead.verdict).to eq("accept")
    end

    it "issues a certificate against the run" do
      certificate = as_tenant(run.account) { run.reload.consent_certificate }

      expect(certificate).to be_present
      expect(as_tenant(run.account) { Certificates::Verifier.call(certificate: certificate) }).to be_valid
    end

    it "settles the bill" do
      expect(run.reload.settled_credits).to eq(17)
      expect(as_tenant(run.account) { run.credit_ledger_entries.entry_type_settlement_refund.count }).to eq(1)
    end

    it "writes each layer's contribution back onto its row" do
      expect(as_tenant(run.account) { run.layer_results.scored.pluck(:score_delta).uniq }).to eq([ 0 ])
    end

    it "leaves a timeline that reads from receipt to certificate" do
      expect(audit_types(run.lead)).to end_with(
        Audit::Events::CONSENSUS_EVALUATED,
        Audit::Events::VERDICT_ISSUED,
        Audit::Events::CERTIFICATE_ISSUED,
        Audit::Events::CREDITS_SETTLED
      )
    end
  end

  describe "the buyer's CRM" do
    it "gains the accepted lead, so the same person resubmitted tomorrow is a duplicate" do
      run = claimed_run(email: "maria@example.com", phone: "+13105550142")

      finalize(run)

      record = as_tenant(run.account) { CrmRecord.find_by!(external_ref: run.lead.public_id) }
      expect(record.phone_normalized).to eq(run.lead.phone_normalized)
      expect(record.source_created_at).to be_within(1.second).of(run.lead.submitted_at)
    end

    it "does not gain a rejected lead, which the buyer never bought" do
      run = claimed_run(verdicts: { "dnc" => "dnc_listed" })

      finalize(run)

      expect(as_tenant(run.account) { run.reload.consensus_verdict.verdict }).to eq("reject")
      expect(as_tenant(run.account) { CrmRecord.exists?(external_ref: run.lead.public_id) }).to be(false)
    end

    it "does not gain a lead held for review" do
      run = claimed_run(verdicts: { "anura" => "suspect_anonymizer" })

      finalize(run)

      expect(as_tenant(run.account) { run.reload.consensus_verdict.verdict }).to eq("review")
      expect(as_tenant(run.account) { CrmRecord.exists?(external_ref: run.lead.public_id) }).to be(false)
    end
  end

  describe "a refundable run" do
    it "gives back the layers that never ran" do
      run = claimed_run("acct_medicareedge", layer_states: { "voice" => "not_applicable" })

      finalize(run)

      expect(run.reload.settled_credits).to eq(16)
    end
  end

  describe "being delivered twice" do
    let(:run) { claimed_run }

    it "changes nothing the second time" do
      finalize(run)
      before_counts = table_counts(run.account)

      finalize(run)

      expect(table_counts(run.account)).to eq(before_counts)
    end

    def table_counts(account)
      as_tenant(account) do
        {
          verdicts: ConsensusVerdict.count,
          certificates: ConsentCertificate.count,
          ledger: CreditLedgerEntry.count,
          crm: CrmRecord.count,
          balance: account.reload.credit_balance,
          audits: ActsAsTenant.without_tenant { AuditEvent.count }
        }
      end
    end
  end

  describe "guards" do
    it "refuses a run nobody claimed, since the gate is the only door in" do
      run = claimed_run
      as_tenant(run.account) { run.update!(status: "running") }

      expect { finalize(run) }.to raise_error(Errors::InvalidTransition, /not finalizing/)
    end

    it "returns the verdict already issued when the run is already closed" do
      run = claimed_run
      verdict = finalize(run).value

      expect(finalize(run.reload).value).to eq(verdict)
    end
  end

  describe "reached from the pipeline" do
    it "completes a run end to end when the last layer job finishes" do
      account = fixture_account("acct_autoinsure")
      run = as_tenant(account) do
        lead = create(:lead, account: account)
        layer_keys = account.layer_policies.enabled.pluck(:layer_key)
        created = Verification::RunCreator.call(lead: lead, effective_layer_keys: layer_keys).value
        ApplicationRecord.transaction do
          Credits::Reservation.call(account: account, run: created, layer_keys: layer_keys)
        end
        created.update!(status: "running")
        created
      end

      layer_keys = as_tenant(account) { run.layer_results.outstanding.pluck(:layer_key) }
      perform_enqueued_jobs do
        layer_keys.each { |layer_key| VerificationLayerJob.perform_now(run.id, layer_key) }
      end

      expect(run.reload.status).to eq("completed")
      expect(as_tenant(account) { run.consent_certificate }).to be_present
    end
  end
end
