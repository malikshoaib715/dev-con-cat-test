# frozen_string_literal: true

class LeadPolicy < ApplicationPolicy
  def index?  = account_member?
  def show?   = same_account?

  # Re-running a held or undispatched verification spends credits, so it is an
  # administrative act rather than a day-to-day one.
  def reverify? = same_account? && account_admin?
end
