# frozen_string_literal: true

class ConsensusVerdict < ApplicationRecord
  acts_as_tenant :account

  VERDICTS = %w[accept review reject].freeze

  enum :verdict, VERDICTS.index_by(&:itself), prefix: true, validate: true

  belongs_to :verification_run

  validates :score, numericality: { only_integer: true, in: 0..100 }
  validates :issued_at, presence: true

  scope :recent_first, -> { order(issued_at: :desc) }
end
