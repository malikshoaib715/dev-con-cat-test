# frozen_string_literal: true

# Deliberately NOT acts_as_tenant: authentication happens before a tenant is
# known (Devise looks a user up by email on a session-less request), so User is
# the one tenant-owned table scoped explicitly through `account.users`.
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
