require "rails_helper"

RSpec.describe CrmRecord do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  before { ActsAsTenant.current_tenant = account }

  it "requires the buyer's own reference and when their CRM created it" do
    record = build(:crm_record, account: account, external_ref: nil, source_created_at: nil)

    expect(record).not_to be_valid
    expect(record.errors[:external_ref]).to be_present
    expect(record.errors[:source_created_at]).to be_present
  end

  it "keeps a CRM reference unique inside one account" do
    create(:crm_record, account: account, external_ref: "ME-88213")

    expect(build(:crm_record, account: account, external_ref: "ME-88213")).not_to be_valid
  end

  it "lets two buyers hold the same reference, because their CRMs are unrelated" do
    create(:crm_record, account: account, external_ref: "ME-88213")

    as_tenant(other_account) do
      expect(build(:crm_record, account: other_account, external_ref: "ME-88213")).to be_valid
    end
  end

  describe "identity matching" do
    let!(:known)   { create(:crm_record, account: account, phone_normalized: "+17135550173", email_normalized: "patricia.nguyen@gmail.com") }
    let!(:unknown) { create(:crm_record, account: account, phone_normalized: nil, email_normalized: nil) }

    it "matches on a normalized phone" do
      expect(described_class.matching_phone("+17135550173")).to contain_exactly(known)
    end

    it "matches on a normalized email" do
      expect(described_class.matching_email("patricia.nguyen@gmail.com")).to contain_exactly(known)
    end

    it "never treats a missing identifier as a match, which would duplicate every blank record" do
      expect(described_class.matching_phone(nil)).to be_empty
      expect(described_class.matching_email(nil)).to be_empty
      expect(described_class.matching_phone(nil)).not_to include(unknown)
    end
  end

  it "joins the name for display without leaving a stray space" do
    expect(build(:crm_record, first_name: "Emily", last_name: "Watson").full_name).to eq("Emily Watson")
    expect(build(:crm_record, first_name: "Emily", last_name: nil).full_name).to eq("Emily")
    expect(build(:crm_record, first_name: nil, last_name: nil).full_name).to be_nil
  end
end
