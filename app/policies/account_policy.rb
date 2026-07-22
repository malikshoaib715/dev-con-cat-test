# frozen_string_literal: true

# Cross-account visibility is a platform-operator power and lives only here.
class AccountPolicy < ApplicationPolicy
  def index? = super_admin?
  def show?  = super_admin?

  private

  def super_admin?
    signed_in? && user.super_admin?
  end
end
