module LayerProcessing
  # Runs a processor against a fixture persona exactly as the job will: the lead's
  # identity is what the gateway looks the payload up by.
  def process_fixture_lead(lead_ref, **overrides)
    lead = fixture_lead(lead_ref, **overrides)
    as_tenant(lead.account) { described_class.call(lead: lead) }
  end

  # For branches the twelve fixtures do not cover, the vendor's answer is supplied
  # directly rather than inventing a thirteenth persona.
  def process_payload(payload, lead: nil)
    lead ||= begin
      account = create(:account)
      as_tenant(account) { create(:lead, account: account) }
    end

    allow(Providers::Gateway).to receive(:fetch)
      .with(layer_key: described_class.layer_key, lead: lead)
      .and_return(payload)

    as_tenant(lead.account) { described_class.call(lead: lead) }
  end

  # Every weighted signal a processor emits has to exist in that layer's seeded
  # weights, or the consensus engine would look it up and silently score zero.
  def expect_signals_to_be_weighted(outcome)
    return if outcome.signals.empty?

    weights = LayerDefinition.find_by!(key: described_class.layer_key).default_weights
    expect(weights.keys).to include(*outcome.signals)
  end
end

RSpec.configure do |config|
  config.include LayerProcessing, type: :layer
  config.define_derived_metadata(file_path: %r{/spec/services/layers/}) do |metadata|
    metadata[:type] = :layer
  end
end
