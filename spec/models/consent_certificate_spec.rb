require "rails_helper"

RSpec.describe ConsentCertificate do
  let(:account) { create(:account) }

  before { ActsAsTenant.current_tenant = account }

  it "is immutable once issued" do
    certificate = create(:consent_certificate, account: account)

    expect(certificate).to be_readonly
    expect { certificate.update!(verdict: "reject") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "carries no updated_at column, because there is no such thing as an updated certificate" do
    expect(described_class.column_names).not_to include("updated_at")
  end

  it "keeps the chain sequence unique per account" do
    create(:consent_certificate, account: account, sequence_number: 1)
    duplicate = build(:consent_certificate, account: account, sequence_number: 1)

    expect(duplicate).not_to be_valid
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "lets two accounts each start their own chain at one" do
    other_account = create(:account)
    create(:consent_certificate, account: account, sequence_number: 1)

    other = as_tenant(other_account) { create(:consent_certificate, account: other_account, sequence_number: 1) }

    expect(other).to be_persisted
  end
end
