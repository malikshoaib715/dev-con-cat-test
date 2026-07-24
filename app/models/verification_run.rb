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
  #
  # `finalizing` is included too, and is not an outcome: it is a claim that
  # somebody is finalizing this run. The claim commits before FinalizeRunJob is
  # enqueued, so a queue that is unreachable in that instant leaves a run nothing
  # will ever pick up — and finalization takes milliseconds, so one still in that
  # state minutes later is abandoned. `updated_at` is what the gate stamps when it
  # claims, which is why staleness is asked of it as well as of creation.
  scope :stuck, -> {
    stale_before = LayerResult::STALE_CLAIM_AFTER.ago

    where(status: %w[pending running finalizing])
      .where(created_at: ..stale_before)
      .where(updated_at: ..stale_before)
      .where.not(id: LayerResult.claimed_since(stale_before).select(:verification_run_id))
  }

  def outstanding_layer_results
    layer_results.where(status: %w[pending processing])
  end
end
