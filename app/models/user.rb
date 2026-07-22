# frozen_string_literal: true

# Deliberately NOT acts_as_tenant, and the one documented exception to "every
# tenant model is scoped at the query layer". Authentication
# happens before a tenant exists: Devise looks a user up by email on a
# session-less request, and a tenant-scoped default scope would make that
# impossible without first knowing the account the visitor is trying to reach.
#
# The compensating controls are:
#   * email is globally unique, so a lookup can never straddle two accounts;
#   * the users_account_matches_role CHECK pins account_id to the role;
#   * Pundit denies by default on every user-facing action.
#
# Standing rule for anything that lists or manages users: load through
# `account.users`, never `User.where(...)`.
class User < ApplicationRecord
  # registerable is off on purpose: users are seeded or invited, never self-served.
  devise :database_authenticatable, :rememberable, :validatable

  ROLES = %w[super_admin account_admin member].freeze

  enum :role, ROLES.index_by(&:itself), validate: true

  belongs_to :account, optional: true

  validates :name, presence: true
  validates :account, presence: true, unless: :super_admin?
  validates :account, absence: true, if: :super_admin?

  scope :ordered_by_name, -> { order(:name) }

  def manages_account?
    super_admin? || account_admin?
  end
end
