# frozen_string_literal: true

# Per-layer policy as data: cost, whether it can hard-stop a lead, whether the
# lead fails open or closed when the layer is unavailable, and the default
# weights the consensus engine scores with. Tuning these needs no deploy.
class LayerDefinition < ApplicationRecord
  CRITICALITIES = %w[required optional].freeze

  enum :criticality, CRITICALITIES.index_by(&:itself), validate: true

  validates :key, presence: true, uniqueness: true, inclusion: { in: ->(_) { Layers::Registry.keys } }
  validates :name, presence: true
  validates :cost_credits, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :position, presence: true, uniqueness: true

  scope :ordered, -> { order(:position) }

  # A required layer that could not answer caps the verdict at REVIEW; an
  # optional one is allowed to fail open.
  def fail_closed?
    required?
  end
end
