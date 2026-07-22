# frozen_string_literal: true

# One row per layer per run, pre-created at ingestion so the three states the
# rubric cares about — not_enabled, not_applicable, completed-with-a-verdict —
# are first-class from t0 rather than inferred from absence.
class LayerResult < ApplicationRecord
  acts_as_tenant :account

  STATUSES       = %w[not_enabled not_applicable pending processing completed errored].freeze
  TERMINAL       = %w[not_enabled not_applicable completed errored].freeze
  PANEL_VERDICTS = %w[pass warn fail skip].freeze

  enum :status,        STATUSES.index_by(&:itself), validate: true
  enum :panel_verdict, PANEL_VERDICTS.index_by(&:itself), prefix: true, validate: { allow_nil: true }

  belongs_to :verification_run

  validates :layer_key,
            presence: true,
            inclusion: { in: ->(_) { Layers::Registry.keys } },
            uniqueness: { scope: :verification_run_id }

  scope :outstanding, -> { where(status: %w[pending processing]) }
  scope :scored,      -> { where(status: "completed") }
  scope :ordered,     -> { order(:layer_key) }

  def terminal?
    TERMINAL.include?(status)
  end

  def label
    Layers::Registry.label(layer_key)
  end
end
