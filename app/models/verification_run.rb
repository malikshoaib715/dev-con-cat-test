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

  # Runs nothing is working on any more, and which can therefore be driven again.
  #
  # Status alone cannot decide this. A `running` run whose worker was killed
  # mid-layer looks exactly like one that is mid-flight, and a fan-out that only
  # partly reached the queue leaves a `running` run with layers nobody will ever
  # pick up — Sidekiq only redelivers jobs that raised, so neither recovers on its
  # own. What separates them is whether any claim is still fresh, so that is what
  # is asked. `pending` is included for the run that was never dispatched at all.
  scope :stuck, -> {
    where(status: %w[pending running])
      .where(created_at: ..LayerResult::STALE_CLAIM_AFTER.ago)
      .where.not(id: LayerResult.claimed_since(LayerResult::STALE_CLAIM_AFTER.ago).select(:verification_run_id))
  }

  def outstanding_layer_results
    layer_results.where(status: %w[pending processing])
  end
end
