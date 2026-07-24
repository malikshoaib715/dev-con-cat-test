require "rails_helper"

RSpec.describe "the public consent verifier" do
  let(:account) { create(:account) }

  let(:certificate) do
    evidence = {
      "lead" => { "public_id" => "L-1001" },
      "pixel" => { "page_url" => "https://solar-savings.example.com/quote" },
      "session" => { "visit_ip" => "76.14.201.33", "submit_ip" => "76.14.201.33" },
      "consensus" => { "verdict" => "accept", "score" => 100, "reasons" => [ "all enabled layers passed" ],
                       "flags" => [] },
      "layers" => { "dnc" => { "status" => "completed", "detail" => "callable, window open" } },
      "trustedform" => { "reference" => "https://cert.example/abc", "status" => "verified" }
    }

    as_tenant(account) do
      create(:consent_certificate, account: account, evidence: evidence,
                                   evidence_hash: Certificates::CanonicalJson.hexdigest(evidence),
                                   sequence_number: 1)
    end
  end

  it "renders without a session, because a certificate only its owner can check is worthless" do
    get verify_certificate_path(certificate.public_id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("VALID", "L-1001", "callable, window open")
  end

  it "shows every layer in the registry, not only the ones that answered" do
    get verify_certificate_path(certificate.public_id)

    Layers::Registry.entries.each { |entry| expect(response.body).to include(entry.label) }
  end

  it "reports tampered evidence as tampered rather than failing" do
    as_tenant(account) do
      ConsentCertificate.where(id: certificate.id).update_all(evidence: { "verdict" => "reject" })
    end

    get verify_certificate_path(certificate.public_id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("TAMPERED")
  end

  it "answers JSON with both digests so a machine can check the work" do
    get verify_certificate_path(certificate.public_id, format: :json)

    body = response.parsed_body
    expect(body["status"]).to eq("VALID")
    expect(body["evidence_hash"]).to eq(body["recomputed_hash"])
    expect(body.dig("evidence", "consensus", "verdict")).to eq("accept")
  end

  it "is not found when the id does not exist" do
    get verify_certificate_path("cert_nothinghere")

    expect(response).to have_http_status(:not_found)
  end
end
