# frozen_string_literal: true

class VerificationRun < ApplicationRecord
  acts_as_tenant :account

  STATUSES = %w[pending running finalizing completed failed].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :lead

  has_many :layer_results,      dependent: :destroy
  has_one  :consensus_verdict,  dependent: :destroy
  has_one  :consent_certificate, dependent: :restrict_with_error
  has_many :credit_ledger_entries, dependent: :nullify

  validates :reserved_credits, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :recent_first, -> { order(created_at: :desc) }
  # Recoverable runs: nothing was ever dispatched for them (Redis was down, or a
  # lead was held for credits), so they can be re-driven safely.
  scope :stuck, -> { where(status: "pending").where(created_at: ..5.minutes.ago) }

  def outstanding_layer_results
    layer_results.where(status: %w[pending processing])
  end
end
