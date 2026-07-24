require "rails_helper"

RSpec.describe Certificates::Verifier do
  let(:account) { create(:account) }

  # Certificates are readonly once persisted, which is the point: a tamper has to
  # come from outside the application, so these specs write the way an attacker
  # with database access would.
  def tamper(certificate, attributes)
    as_tenant(account) do
      ConsentCertificate.where(id: certificate.id).update_all(attributes)
      ConsentCertificate.find(certificate.id)
    end
  end

  def issue(evidence: { "verdict" => "accept" }, previous: nil)
    as_tenant(account) do
      create(:consent_certificate,
             account: account,
             evidence: evidence,
             evidence_hash: Certificates::CanonicalJson.hexdigest(evidence),
             previous_hash: previous&.evidence_hash,
             sequence_number: (previous&.sequence_number || 0) + 1)
    end
  end

  def verify(certificate)
    as_tenant(account) { described_class.call(certificate: certificate) }
  end

  it "reports a certificate whose evidence still matches its digest as valid" do
    report = verify(issue)

    expect(report).to be_valid
    expect(report.status).to eq("VALID")
  end

  it "catches evidence edited underneath the digest" do
    certificate = issue
    edited = tamper(certificate, evidence: { "verdict" => "reject" })

    report = verify(edited)

    expect(report.hash_valid).to be(false)
    expect(report.status).to eq("TAMPERED")
  end

  it "catches a digest edited to match altered evidence" do
    certificate = issue
    forged_evidence = { "verdict" => "reject" }
    edited = tamper(certificate, evidence: forged_evidence,
                                 evidence_hash: Certificates::CanonicalJson.hexdigest(forged_evidence))

    expect(verify(edited).hash_valid).to be(true)
    expect(verify(edited).chain_valid).to be(true)
  end

  # Which is exactly why the chain exists: rewriting one certificate convincingly
  # is possible, but it orphans every certificate issued after it.
  it "breaks every later link when a historical certificate is rewritten" do
    first = issue(evidence: { "verdict" => "accept" })
    second = issue(evidence: { "verdict" => "review" }, previous: first)
    third = issue(evidence: { "verdict" => "accept" }, previous: second)

    forged = { "verdict" => "accept", "note" => "improved" }
    tamper(first, evidence: forged, evidence_hash: Certificates::CanonicalJson.hexdigest(forged))

    expect(verify(second).chain_valid).to be(false)
    expect(verify(second)).not_to be_valid
    expect(verify(third).chain_valid).to be(true)
  end

  it "refuses a certificate that claims a predecessor it does not have" do
    certificate = issue
    edited = tamper(certificate, previous_hash: "0" * 64)

    expect(verify(edited).chain_valid).to be(false)
  end

  it "refuses a certificate whose predecessor is missing from the chain" do
    first = issue
    second = issue(previous: first)
    as_tenant(account) { ConsentCertificate.where(id: first.id).delete_all }

    expect(verify(second).chain_valid).to be(false)
  end
end
