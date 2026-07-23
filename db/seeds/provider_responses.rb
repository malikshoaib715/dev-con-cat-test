module Seeds
  # The vendor fixture store Providers::Gateway reads. Not tenant-owned: a
  # provider's answer about an identity is the same whoever asks.
  #
  # Each row is stamped with the identity it describes as well as the lead it came
  # from, so the gateway can replay a fixture scenario for a lead it has never
  # seen — which is what makes the live demo show real detections.
  module ProviderResponses
    # duplicate_detection is absent by design: it has no vendor. It is answered
    # from the buyer's own crm_records.
    VENDOR_LAYER_KEYS = (Layers::Registry.keys - %w[duplicate_detection]).freeze

    def self.load!
      identities = lead_identities

      VENDOR_LAYER_KEYS.each do |layer_key|
        MockData.read("providers", "#{layer_key}.json").fetch("results").each do |lead_ref, payload|
          upsert(layer_key, lead_ref, payload, identities.fetch(lead_ref, {}))
        end
      end

      puts "  provider_responses: #{ProviderResponse.count}"
    end

    def self.upsert(layer_key, lead_ref, payload, identity)
      response = ProviderResponse.find_or_initialize_by(layer_key: layer_key, lead_ref: lead_ref)
      response.update!(
        payload: payload,
        email_normalized: identity[:email_normalized],
        phone_normalized: identity[:phone_normalized]
      )
    end

    # Normalized through the same functions the live ingestion path uses, so a
    # visitor typing a persona's number in any format still matches.
    def self.lead_identities
      MockData.read("leads.json").fetch("leads").to_h do |lead|
        [
          lead.fetch("lead_id"),
          {
            email_normalized: Leads::Normalizer.email(lead["email"]),
            phone_normalized: Leads::Normalizer.phone(lead["phone"])
          }
        ]
      end
    end
  end
end
