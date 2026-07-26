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

  describe "a delivery that resumes a half-finished finalization" do
    # One step earlier than the case below: the certificate exists but the bill was
    # never settled. The failed re-issue leaves an unsaved certificate in the
    # ACCOUNT's association target this time; settlement's account.lock! reloads
    # the row and must clear it before its own account.update! autosaves the
    # corpse into the same unique index.
    it "settles and closes a run that crashed between certificate and settlement" do
      run = claimed_run
      as_tenant(run.account) do
        verdict = create(:consensus_verdict, account: run.account, verification_run: run,
                                             policy_snapshot: { "engine_version" => "1.0" })
        Certificates::Issuer.call(run: run, consensus_verdict: verdict)
      end

      expect(finalize(run)).to be_success
      expect(run.reload.status).to eq("completed")
      as_tenant(run.account) do
        expect(ConsentCertificate.where(verification_run_id: run.id).count).to eq(1)
        expect(run.credit_ledger_entries.entry_type_settlement_refund.count).to eq(1)
      end
    end

    # The crash this survives: the certificate was issued and the bill settled, but
    # the process died before the run was closed. The redelivery has to finish the
    # job on the very objects that already did half of it — which is why the issuer
    # creates by foreign key. Attaching a certificate that then loses the unique
    # index leaves the failed record hanging off this run, and the close below
    # autosaves it: the run could never reach `completed` and the job would retry
    # forever.
    it "closes a run whose certificate and settlement already exist" do
      run = claimed_run
      finalize(run)
      as_tenant(run.account) { run.update!(status: "finalizing", completed_at: nil) }

      expect(finalize(run)).to be_success
      expect(run.reload.status).to eq("completed")
      as_tenant(run.account) do
        expect(ConsentCertificate.where(verification_run_id: run.id).count).to eq(1)
        expect(run.credit_ledger_entries.entry_type_settlement_refund.count).to eq(1)
      end
    end
  end

  # The completion gate is supposed to make this impossible, so this is the proof
  # that the defence behind it holds too: unique indexes on the verdict, the
  # certificate and the ledger entry type, and a savepoint around the verdict
  # insert so losing the race does not abort the whole finalization.
  describe "two finalizers racing the same run", :real_transactions do
    it "issues one verdict, one certificate and one refund" do
      load_static_seeds
      run = claimed_run

      results = in_parallel(2, tenant: run.account) { described_class.call(run: run) }

      expect(results.map(&:success?)).to eq([ true, true ])
      as_tenant(run.account) do
        expect(ConsensusVerdict.where(verification_run_id: run.id).count).to eq(1)
        expect(ConsentCertificate.where(verification_run_id: run.id).count).to eq(1)
        expect(run.credit_ledger_entries.entry_type_settlement_refund.count).to eq(1)
      end
      expect(run.reload.status).to eq("completed")
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

    # The promise the CRM append exists to keep, end to end: an accepted unknown
    # identity enters the buyer's CRM, and the same person on a new session is
    # refused as an exact duplicate that names the first lead.
    it "rejects tomorrow's resubmission of a lead accepted today" do
      account = fixture_account("acct_solarpro")
      pixel = fixture_pixel_for(account)
      identity = { first_name: "Nadia", last_name: "Osei",
                   email: "nadia.osei@example.com", phone: "+13105557001" }

      first = second = nil
      perform_enqueued_jobs do
        as_tenant(account) do
          first = Leads::IngestionService.call(pixel: pixel,
            attributes: { session_id: "probe-day-1", fields: identity }).value.lead
          second = Leads::IngestionService.call(pixel: pixel,
            attributes: { session_id: "probe-day-2", fields: identity }).value.lead
        end
      end

      expect(first.reload.verdict).to eq("accept")
      expect(second.reload.verdict).to eq("reject")
      expect(second.flags).to include("duplicate")
      verdict = as_tenant(account) { second.verification_run.consensus_verdict }
      expect(verdict.hard_stop_layer).to eq("duplicate_detection")
      expect(verdict.reasons.first).to include(first.public_id)
    end

    # The gap a reviewer finds in one try, by typing nonsense into the phone box.
    # Every vendor fixture answers about an identity rather than refusing an
    # unusable one, so all three phone lookups would have reported a clean pass
    # about a lead nobody can dial — and the certificate would have carried all
    # three claims. They report that they could not judge, the compliance gap
    # caps the verdict at review, and the buyer is refunded the checks that never
    # ran. Ingestion still accepts the lead: it has an email, and a real buyer
    # would rather hold a reviewable lead than lose the record entirely.
    it "will not accept a lead whose phone number is not a phone number" do
      account = fixture_account("acct_solarpro")
      pixel = fixture_pixel_for(account)

      lead = nil
      perform_enqueued_jobs do
        as_tenant(account) do
          lead = Leads::IngestionService.call(pixel: pixel, attributes: {
            session_id: "probe-junk-phone",
            fields: { first_name: "Abc", last_name: "Def",
                      email: "abc.def@example.com", phone: ",dc kwc qkcjn q" }
          }).value.lead
        end
      end

      expect(lead.reload.verdict).to eq("review")
      expect(lead.flags).to include("required_layer_unjudged")

      run = as_tenant(account) { lead.verification_run }
      rows = as_tenant(account) { run.layer_results.index_by(&:layer_key) }
      phone_keyed = %w[dnc blacklist_alliance phone_validation]
      phone_keyed.each do |layer_key|
        expect(rows.fetch(layer_key).status).to eq("not_applicable")
        expect(rows.fetch(layer_key).detail).to eq("no dialable phone number on the lead")
        expect(rows.fetch(layer_key).verdict).to be_nil
      end

      # The certificate says the same thing the run does — a check that did not
      # run must never read as one that passed.
      certificate = as_tenant(account) { lead.consent_certificate }
      expect(certificate.evidence["layers"]["dnc"]["status"]).to eq("not_applicable")

      # And the buyer pays for the seven checks that answered, not the ten booked.
      unrun = LayerDefinition.where(key: phone_keyed).sum(:cost_credits)
      expect(run.settled_credits).to eq(run.reserved_credits - unrun)
    end

    # The other half of the same lead. This number is fifteen digits on an
    # unassigned country code — a legal E.164 length, so no shape check can call
    # it impossible and the phone layers judge it as they would any number. What
    # is knowable is the address: `fgh@hg` has no mail exchanger anywhere, and
    # that finding alone is enough to keep the lead off an unqualified accept.
    it "reviews a lead whose address could never receive mail" do
      account = fixture_account("acct_solarpro")
      pixel = fixture_pixel_for(account)

      lead = nil
      perform_enqueued_jobs do
        as_tenant(account) do
          lead = Leads::IngestionService.call(pixel: pixel, attributes: {
            session_id: "probe-unreachable-address",
            fields: { first_name: "Abc", last_name: "Def",
                      email: "fgh@hg", phone: "9+30976543234567" }
          }).value.lead
        end
      end

      expect(lead.reload.verdict).to eq("review")

      row = as_tenant(account) { lead.verification_run.layer_results.find_by!(layer_key: "email_validation") }
      expect(row.verdict).to eq("unreachable_address")
      expect(row.score_delta).to eq(-35)

      verdict = as_tenant(account) { lead.verification_run.consensus_verdict }
      expect(verdict.score).to eq(65)
      expect(verdict.reasons.first).to include("cannot receive mail")
    end
  end
end
