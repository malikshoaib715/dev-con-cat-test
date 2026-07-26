# frozen_string_literal: true

# Cross-account visibility is a platform-operator power and lives only here.
class AccountPolicy < ApplicationPolicy
  def index? = platform_operator?
  def show?  = platform_operator?
end
