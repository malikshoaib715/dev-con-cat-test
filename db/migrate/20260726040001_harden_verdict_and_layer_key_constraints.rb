class HardenVerdictAndLayerKeyConstraints < ActiveRecord::Migration[8.1]
  # Spelled out rather than read from Layers::Registry: a migration has to keep
  # replaying correctly after the constant changes. The drift this could cause is
  # caught by spec/models/schema_constraints_spec.rb, which asserts the constraint
  # and the registry still agree.
  CANONICAL_LAYER_KEYS = %w[
    vpn_proxy anura trustedform blacklist_alliance dnc
    phone_validation email_validation enrichment duplicate_detection voice
  ].freeze

  def up
    add_check_constraint :consent_certificates,
                         "verdict IN ('accept', 'review', 'reject')",
                         name: "consent_certificates_verdict_valid"

    layer_key_columns.each do |table, column|
      add_check_constraint table,
                           "#{column} IN (#{quoted_layer_keys})",
                           name: "#{table}_#{column}_canonical"
    end
  end

  def down
    remove_check_constraint :consent_certificates, name: "consent_certificates_verdict_valid"

    layer_key_columns.each do |table, column|
      remove_check_constraint table, name: "#{table}_#{column}_canonical"
    end
  end

  private

  # Layer keys are code, not policy: each one names a processor class. An alias
  # anywhere (`trusted_form`, `voice_ai`) silently breaks fixture lookup, cost
  # lookup and the panel labels, so the database refuses one.
  def layer_key_columns
    {
      layer_definitions: :key,
      layer_policies: :layer_key,
      layer_results: :layer_key,
      provider_responses: :layer_key
    }
  end

  def quoted_layer_keys
    CANONICAL_LAYER_KEYS.map { |key| "'#{key}'" }.join(", ")
  end
end
