require "rails_helper"

# The full role x action matrix, written down once. Authorization is enforced,
# not merely hidden in the UI, so every one of these is a policy question rather
# than a view question.
RSpec.describe "Authorization matrix" do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:member)        { create(:user, account: account, role: "member") }
  let(:admin)         { create(:user, :account_admin, account: account) }
  let(:super_admin)   { create(:user, :super_admin) }
  let(:outsider)      { create(:user, account: other_account, role: "account_admin") }

  let(:lead)        { as_tenant(account) { create(:lead, account: account) } }
  let(:pixel)       { as_tenant(account) { create(:pixel, account: account) } }
  let(:certificate) { as_tenant(account) { create(:consent_certificate, account: account) } }
  let(:audit_event) { as_tenant(account) { create(:audit_event, account: account) } }
  let(:ledger)      { as_tenant(account) { create(:credit_ledger_entry, account: account) } }

  describe "leads" do
    it "lets anyone in the account read them" do
      expect(LeadPolicy.new(member, lead).show?).to be(true)
      expect(LeadPolicy.new(admin, lead).show?).to be(true)
    end

    it "hides them from a user in another account" do
      expect(LeadPolicy.new(outsider, lead).show?).to be(false)
    end

    it "restricts re-verification, which spends credits, to account admins" do
      expect(LeadPolicy.new(member, lead).reverify?).to be(false)
      expect(LeadPolicy.new(admin, lead).reverify?).to be(true)
      expect(LeadPolicy.new(outsider, lead).reverify?).to be(false)
    end
  end

  describe "pixels" do
    it "is read-only for a member" do
      expect(PixelPolicy.new(member, pixel).show?).to be(true)
      expect(PixelPolicy.new(member, pixel).update?).to be(false)
      expect(PixelPolicy.new(member, pixel).destroy?).to be(false)
      expect(PixelPolicy.new(member, Pixel).create?).to be(false)
    end

    it "is writable by an account admin, within their own account only" do
      expect(PixelPolicy.new(admin, pixel).update?).to be(true)
      expect(PixelPolicy.new(admin, Pixel).create?).to be(true)
      expect(PixelPolicy.new(outsider, pixel).update?).to be(false)
    end
  end

  describe "certificates, audit events and the ledger" do
    it "are readable inside the account and invisible outside it" do
      expect(ConsentCertificatePolicy.new(member, certificate).show?).to be(true)
      expect(ConsentCertificatePolicy.new(outsider, certificate).show?).to be(false)

      expect(AuditEventPolicy.new(member, audit_event).show?).to be(true)
      expect(AuditEventPolicy.new(outsider, audit_event).show?).to be(false)

      expect(CreditLedgerEntryPolicy.new(member, ledger).show?).to be(true)
      expect(CreditLedgerEntryPolicy.new(outsider, ledger).show?).to be(false)
    end
  end

  describe "the platform console" do
    it "is reachable only by a platform operator" do
      expect(AccountPolicy.new(super_admin, account).index?).to be(true)
      expect(AccountPolicy.new(admin, account).index?).to be(false)
      expect(AccountPolicy.new(member, account).index?).to be(false)
    end
  end

  describe "the default" do
    it "denies everything that has not been explicitly granted" do
      policy = ApplicationPolicy.new(admin, lead)

      expect(policy.index?).to be(false)
      expect(policy.show?).to be(false)
      expect(policy.create?).to be(false)
      expect(policy.update?).to be(false)
      expect(policy.destroy?).to be(false)
    end

    it "denies an anonymous visitor outright" do
      expect(LeadPolicy.new(nil, lead).show?).to be(false)
      expect(LeadPolicy.new(nil, Lead).index?).to be(false)
    end
  end

  describe "policy scopes" do
    it "narrows a collection to the caller's account" do
      mine = lead
      theirs = as_tenant(other_account) { create(:lead, account: other_account) }

      resolved = ActsAsTenant.without_tenant { ApplicationPolicy::Scope.new(member, Lead).resolve }

      expect(resolved).to include(mine)
      expect(resolved).not_to include(theirs)
    end

    it "resolves to nothing for an anonymous visitor" do
      lead

      resolved = ActsAsTenant.without_tenant { ApplicationPolicy::Scope.new(nil, Lead).resolve }

      expect(resolved).to be_empty
    end

    it "spans accounts for a platform operator" do
      mine = lead
      theirs = as_tenant(other_account) { create(:lead, account: other_account) }

      resolved = ActsAsTenant.without_tenant { ApplicationPolicy::Scope.new(super_admin, Lead).resolve }

      expect(resolved).to contain_exactly(mine, theirs)
    end
  end
end
