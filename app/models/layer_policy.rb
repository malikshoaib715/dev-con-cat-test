# frozen_string_literal: true

# A buyer's overrides on top of the layer defaults: which layers they pay for,
# which soft signals they want promoted to hard stops, and any reweighting.
class LayerPolicy < ApplicationRecord
  acts_as_tenant :account

  validates :layer_key,
            presence: true,
            inclusion: { in: ->(_) { Layers::Registry.keys } },
            uniqueness: { scope: :account_id }

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:layer_key) }
end
