# frozen_string_literal: true

# The seeded stand-in for the vendor APIs, read only through Providers::Gateway.
# Not tenant-owned: a provider's answer about an identity is the same whoever
# asks, and two accounts submitting the same person get the same vendor verdict.
class ProviderResponse < ApplicationRecord
  validates :layer_key, presence: true, inclusion: { in: ->(_) { Layers::Registry.keys } }

  # The unique index treats NULL lead_refs as distinct, so the model agrees:
  # a layer may hold many identity-keyed rows that belong to no seeded lead.
  validates :layer_key, uniqueness: { scope: :lead_ref }, if: -> { lead_ref.present? }

  scope :for_layer, ->(layer_key) { where(layer_key: layer_key) }
end
