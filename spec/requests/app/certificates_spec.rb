require "rails_helper"

RSpec.describe "App::Certificates", type: :request do
  let(:solar) { create(:account, name: "SolarPro") }
  let(:medicare) { create(:account, name: "MedicareEdge") }

  def certificate_for(account, **overrides)
    as_tenant(account) do
      run = create(:verification_run, account: account)
      create(:consent_certificate, account: account, verification_run: run, lead: run.lead, **overrides)
    end
  end

  describe "the list" do
    it "shows a member their account's certificates and nobody else's" do
      mine = certificate_for(solar)
      theirs = certificate_for(medicare)
      sign_in create(:user, account: solar, role: "member")

      get app_certificates_path

      expect(response.body).to include(mine.public_id)
      expect(response.body).not_to include(theirs.public_id)
    end
  end

  describe "one certificate" do
    let(:evidence) do
      { "consensus" => { "score" => 90, "reasons" => [ "all enabled layers passed" ] },
        "layers" => { "dnc" => { "status" => "completed", "detail" => "callable, window open" } } }
    end

    let(:certificate) do
      certificate_for(solar, evidence: evidence,
                             evidence_hash: Certificates::CanonicalJson.hexdigest(evidence),
                             sequence_number: 1, previous_hash: nil)
    end

    before { sign_in create(:user, account: solar, role: "member") }

    it "recomputes the digest in front of the reader and calls an intact one valid" do
      get app_certificate_path(certificate)

      expect(response.body).to include("VALID")
      expect(response.body).to include(certificate.evidence_hash)
    end

    it "shows the whole layer table, including the checks that never ran" do
      get app_certificate_path(certificate)

      Layers::Registry.entries.each { |entry| expect(response.body).to include(entry.label) }
    end

    it "links out to the page anybody holding the id can check" do
      get app_certificate_path(certificate)

      expect(response.body).to include(verify_certificate_path(certificate.public_id))
    end

    # The certificate is readonly in Ruby, so tampering has to be done the way a
    # tamperer would: straight at the row.
    it "says TAMPERED when the stored evidence no longer hashes to its digest" do
      as_tenant(solar) do
        ConsentCertificate.where(id: certificate.id)
                          .update_all(evidence: evidence.merge("consensus" => { "score" => 100 }))
      end

      get app_certificate_path(certificate)

      expect(response.body).to include("TAMPERED")
    end

    it "reports another account's certificate as missing rather than as forbidden" do
      theirs = certificate_for(medicare)

      get app_certificate_path(theirs)

      expect(response).to have_http_status(:not_found)
    end
  end
end
