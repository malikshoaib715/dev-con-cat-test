# frozen_string_literal: true

class Account < ApplicationRecord
  include HasPublicId
  public_id_prefix "acct_"

  PLANS    = %w[starter growth enterprise].freeze
  STATUSES = %w[active past_due suspended].freeze

  # Below this many days of runway the super-admin dashboard flags the account.
  LOW_CREDIT_DAYS_TO_ZERO = 3

  enum :plan,   PLANS.index_by(&:itself),    validate: true
  enum :status, STATUSES.index_by(&:itself), validate: true

  has_many :users,                 dependent: :restrict_with_error
  has_many :pixels,                dependent: :restrict_with_error
  has_many :layer_policies,        dependent: :destroy
  has_many :visits,                dependent: :destroy
  has_many :leads,                 dependent: :destroy
  has_many :verification_runs,     dependent: :destroy
  has_many :layer_results,         dependent: :destroy
  has_many :consensus_verdicts,    dependent: :destroy
  has_many :consent_certificates,  dependent: :restrict_with_error
  has_many :credit_ledger_entries, dependent: :destroy
  has_many :audit_events,          dependent: :destroy
  has_many :crm_records,           dependent: :destroy

  validates :name, :billing_email, presence: true
  validates :credit_balance, :monthly_credit_allowance,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cycle_start, :cycle_end, presence: true

  scope :ordered_by_name, -> { order(:name) }

  # Buyers may override the consensus bands without a deploy; the engine reads
  # these through Consensus::Policy, never directly.
  def accept_threshold_override
    settings["accept_threshold"]
  end

  def review_threshold_override
    settings["review_threshold"]
  end

  def allowance_used
    monthly_credit_allowance - credit_balance
  end

  def allowance_used_percent
    return 0 if monthly_credit_allowance.zero?

    ((allowance_used.to_f / monthly_credit_allowance) * 100).round
  end
end
