# frozen_string_literal: true

class CreditLedgerEntryPolicy < ApplicationPolicy
  # Everyone in the account can see what their verifications cost; nobody can
  # move credits from the dashboard.
  def index? = account_member?
  def show?  = same_account?
end
