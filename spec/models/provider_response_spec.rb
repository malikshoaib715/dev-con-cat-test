require "rails_helper"

RSpec.describe ProviderResponse do
  it "is deliberately not tenant-scoped: a vendor's answer about an identity is the same whoever asks" do
    expect(described_class).not_to respond_to(:scoped_by_tenant?)
    expect { described_class.count }.not_to raise_error
  end

  it "accepts only canonical layer keys, in Ruby and in the database" do
    expect(build(:provider_response, layer_key: "trusted_form")).not_to be_valid

    response = create(:provider_response, layer_key: "trustedform")
    expect { response.update_column(:layer_key, "trusted_form") }
      .to raise_error(ActiveRecord::StatementInvalid, /provider_responses_layer_key_canonical/)
  end

  it "holds one row per layer per seeded lead" do
    create(:provider_response, layer_key: "anura", lead_ref: "L-1001")

    expect(build(:provider_response, layer_key: "anura", lead_ref: "L-1001")).not_to be_valid
  end

  it "lets different layers answer for the same lead" do
    create(:provider_response, layer_key: "anura", lead_ref: "L-1001")

    expect(build(:provider_response, layer_key: "dnc", lead_ref: "L-1001")).to be_valid
  end

  # The unique index treats NULLs as distinct, so the model must not be stricter
  # than the database: identity-keyed rows belong to no seeded lead.
  it "allows many identity-keyed rows per layer that reference no lead" do
    create(:provider_response, layer_key: "anura", lead_ref: nil, phone_normalized: "+13105550142")
    second = build(:provider_response, layer_key: "anura", lead_ref: nil, phone_normalized: "+13105550199")

    expect(second).to be_valid
    expect { second.save! }.not_to raise_error
  end

  it "reads back the vendor payload untouched" do
    payload = { "result" => "suspect", "rule_ids" => [ "ANONYMIZER_IP" ], "confidence" => 0.61 }

    response = create(:provider_response, layer_key: "anura", payload: payload)

    expect(response.reload.payload).to eq(payload)
  end

  it "narrows the fixture store to one layer" do
    anura = create(:provider_response, layer_key: "anura")
    create(:provider_response, layer_key: "dnc")

    expect(described_class.for_layer("anura")).to contain_exactly(anura)
  end
end
