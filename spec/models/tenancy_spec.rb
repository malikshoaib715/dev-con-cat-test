require "rails_helper"

# Isolation is enforced at the query layer. These are the model-level proofs;
# the request-level proofs (direct-id access returning 404) live in
# spec/requests.
RSpec.describe "Tenant isolation" do
  let(:solar)    { create(:account, name: "SolarPro") }
  let(:medicare) { create(:account, name: "MedicareEdge") }

  let!(:solar_lead)    { as_tenant(solar)    { create(:lead, account: solar) } }
  let!(:medicare_lead) { as_tenant(medicare) { create(:lead, account: medicare) } }

  it "returns only the current tenant's rows from an unqualified query" do
    as_tenant(solar) do
      expect(Lead.all).to contain_exactly(solar_lead)
    end

    as_tenant(medicare) do
      expect(Lead.all).to contain_exactly(medicare_lead)
    end
  end

  it "cannot reach another tenant's record by primary key" do
    as_tenant(solar) do
      expect { Lead.find(medicare_lead.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it "cannot reach another tenant's record by public id either" do
    as_tenant(solar) do
      expect(Lead.find_by(public_id: medicare_lead.public_id)).to be_nil
    end
  end

  it "refuses to query a tenant-owned model with no tenant set at all" do
    expect { Lead.count }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
    expect { Pixel.first }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
    expect { ConsentCertificate.count }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
  end

  it "spans accounts only inside an explicit without_tenant block" do
    ActsAsTenant.without_tenant do
      expect(Lead.all).to contain_exactly(solar_lead, medicare_lead)
    end
  end

  it "refuses to move a record between tenants after it is written" do
    as_tenant(solar) do
      expect { solar_lead.update!(account: medicare) }
        .to raise_error(ActsAsTenant::Errors::TenantIsImmutable)
    end
  end

  it "scopes every tenant-owned model, not just leads" do
    tenant_models = [ Pixel, LayerPolicy, Visit, Lead, VerificationRun, LayerResult,
                      ConsensusVerdict, ConsentCertificate, CreditLedgerEntry, AuditEvent, CrmRecord ]

    expect(tenant_models).to all(be_scoped_by_tenant)
  end

  # The one documented exception, and the controls that stand in for the default
  # scope it does not have. See DEVIATIONS.md.
  describe "User, which is deliberately not tenant-scoped" do
    it "can be looked up with no tenant set, because authentication precedes tenancy" do
      create(:user, account: solar, email: "dana@solarpro.example")

      expect { User.find_by(email: "dana@solarpro.example") }.not_to raise_error
    end

    it "keeps email globally unique, so a lookup can never straddle two accounts" do
      create(:user, account: solar, email: "shared@example.com")

      expect(build(:user, account: medicare, email: "shared@example.com")).not_to be_valid
    end

    it "still isolates users when loaded the way the application loads them" do
      mine = create(:user, account: solar)
      theirs = create(:user, account: medicare)

      expect(solar.users).to include(mine)
      expect(solar.users).not_to include(theirs)
    end
  end
end
