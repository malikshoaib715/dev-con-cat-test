require "rails_helper"

RSpec.describe Certificates::Issuer do
  before { load_layer_definitions }

  let(:account) { create(:account) }

  def issued_run(verdict: "accept", score: 100, layer_states: {}, **lead_attributes)
    as_tenant(account) do
      lead = create(:lead, account: account, raw_payload: { "trusted_form_cert_url" => "https://cert.example/abc" },
                           **lead_attributes)
      run = Verification::RunCreator.call(lead: lead, effective_layer_keys: enabled_keys).value
      finish_layers(run, layer_states)
      verdict_record = create(:consensus_verdict, account: account, verification_run: run, verdict: verdict,
                                                  score: score, reasons: [ "all enabled layers passed" ],
                                                  policy_snapshot: { "engine_version" => "1.0" })
      [ run, verdict_record ]
    end
  end

  def enabled_keys
    Layers::Registry.keys - [ "voice" ]
  end

  def finish_layers(run, layer_states)
    run.layer_results.outstanding.find_each do |row|
      row.update!(status: layer_states.fetch(row.layer_key, "completed"), verdict: "clean",
                  panel_verdict: "pass", detail: "#{row.layer_key} answered",
                  raw_response: { "signals" => [], "matches_phone" => true }, completed_at: Time.current)
    end
  end

  def issue(run, verdict_record)
    as_tenant(account) { described_class.call(run: run, consensus_verdict: verdict_record) }
  end

  describe "the evidence" do
    it "records all ten layers, whatever state each ended in" do
      run, verdict_record = issued_run(layer_states: { "enrichment" => "errored" })

      evidence = issue(run, verdict_record).value.evidence

      expect(evidence["layers"].keys).to match_array(Layers::Registry.keys)
      expect(evidence.dig("layers", "voice", "status")).to eq("not_enabled")
      expect(evidence.dig("layers", "enrichment", "status")).to eq("errored")
      expect(evidence.dig("layers", "anura", "status")).to eq("completed")
    end

    it "keeps the identity, the page, the decision and the policy that produced it" do
      run, verdict_record = issued_run

      evidence = issue(run, verdict_record).value.evidence

      expect(evidence.dig("lead", "public_id")).to eq(run.lead.public_id)
      expect(evidence.dig("pixel", "public_id")).to eq(run.lead.pixel.public_id)
      expect(evidence.dig("consensus", "verdict")).to eq("accept")
      expect(evidence.dig("consensus", "reasons")).to eq([ "all enabled layers passed" ])
      expect(evidence["policy_snapshot"]).to eq("engine_version" => "1.0")
    end

    it "records where the page was opened from as well as where the form was posted from" do
      run, verdict_record = issued_run(ip_address: "203.0.113.9")
      as_tenant(account) do
        create(:visit, account: account, pixel: run.lead.pixel, session_id: run.lead.session_id,
                       ip_address: "198.51.100.4")
      end

      evidence = issue(run, verdict_record).value.evidence

      expect(evidence.dig("session", "visit_ip")).to eq("198.51.100.4")
      expect(evidence.dig("session", "submit_ip")).to eq("203.0.113.9")
    end

    it "carries the consent proof and what the layer made of it" do
      run, verdict_record = issued_run

      certificate = issue(run, verdict_record).value

      expect(certificate.trustedform_reference).to eq("https://cert.example/abc")
      expect(certificate.evidence.dig("trustedform", "matches_phone")).to be(true)
    end
  end

  describe "the hash" do
    # The regression this whole design exists for: jsonb does not preserve key
    # order, so a digest taken over insertion-ordered JSON stops matching the
    # moment the row is read back.
    it "survives a database round trip" do
      run, verdict_record = issued_run

      certificate = issue(run, verdict_record).value
      reloaded = as_tenant(account) { ConsentCertificate.find(certificate.id) }

      expect(Certificates::CanonicalJson.hexdigest(reloaded.evidence)).to eq(certificate.evidence_hash)
    end

    it "does not depend on the order the evidence was built in" do
      document = { "b" => 1, "a" => { "d" => 2, "c" => [ 3, 4 ] } }
      shuffled = { "a" => { "c" => [ 3, 4 ], "d" => 2 }, "b" => 1 }

      expect(Certificates::CanonicalJson.hexdigest(document))
        .to eq(Certificates::CanonicalJson.hexdigest(shuffled))
    end

    it "does depend on array order, which is meaningful" do
      expect(Certificates::CanonicalJson.hexdigest("reasons" => [ 1, 2 ]))
        .not_to eq(Certificates::CanonicalJson.hexdigest("reasons" => [ 2, 1 ]))
    end
  end

  describe "the chain" do
    it "numbers each certificate after the last one issued to the account" do
      first = issue(*issued_run).value
      second = issue(*issued_run).value

      expect(first.sequence_number).to eq(1)
      expect(second.sequence_number).to eq(2)
      expect(first.previous_hash).to be_nil
      expect(second.previous_hash).to eq(first.evidence_hash)
    end

    it "keeps one account's chain out of another's" do
      issue(*issued_run)
      other = create(:account)
      other_run, other_verdict = as_tenant(other) do
        lead = create(:lead, account: other)
        run = Verification::RunCreator.call(lead: lead, effective_layer_keys: enabled_keys).value
        finish_layers(run, {})
        [ run, create(:consensus_verdict, account: other, verification_run: run) ]
      end

      certificate = as_tenant(other) { described_class.call(run: other_run, consensus_verdict: other_verdict) }.value

      expect(certificate.sequence_number).to eq(1)
      expect(certificate.previous_hash).to be_nil
    end

    # Ten layer jobs per lead and several leads at once means several finalizers
    # can reach issuance together. The account lock is what turns that into a
    # queue; without it two certificates take the same sequence number and the
    # chain forks.
    it "issues gapless sequence numbers when several finalizers race", :real_transactions do
      load_layer_definitions
      pending_issuance = Array.new(4) { issued_run }

      certificates = in_parallel(4, tenant: account) do |index|
        run, verdict_record = pending_issuance[index]
        described_class.call(run: run, consensus_verdict: verdict_record).value
      end

      expect(certificates.map(&:sequence_number).sort).to eq([ 1, 2, 3, 4 ])
      expect(certificates.map(&:previous_hash).compact.uniq.size).to eq(3)
    end
  end

  describe "being called twice" do
    it "returns the certificate that already exists rather than issuing a second" do
      run, verdict_record = issued_run

      first = issue(run, verdict_record).value
      second = issue(run, verdict_record).value

      expect(second.id).to eq(first.id)
      expect(as_tenant(account) { ConsentCertificate.count }).to eq(1)
    end
  end

  it "audits the issuance against the lead" do
    run, verdict_record = issued_run
    certificate = issue(run, verdict_record).value

    event = ActsAsTenant.without_tenant do
      AuditEvent.where(event_type: Audit::Events::CERTIFICATE_ISSUED).last
    end
    expect(event.payload).to include("certificate_id" => certificate.public_id, "sequence_number" => 1)
    expect(event.subject_id).to eq(run.lead.id)
  end
end
