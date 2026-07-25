# frozen_string_literal: true

# Append-only money. `accounts.credit_balance` is a cached projection of this
# table; when they disagree, the ledger wins.
class CreditLedgerEntry < ApplicationRecord
  acts_as_tenant :account

  ENTRY_TYPES = %w[grant reservation settlement_refund adjustment].freeze

  enum :entry_type, ENTRY_TYPES.index_by(&:itself), prefix: true, validate: true

  belongs_to :verification_run, optional: true

  validates :amount, numericality: { only_integer: true }
  validates :balance_after, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :recent_first, -> { order(created_at: :desc) }
  scope :spending,     -> { where(entry_type: %w[reservation settlement_refund]) }
  scope :since,        ->(time) { where(created_at: time..) }

  def readonly?
    persisted?
  end
end
