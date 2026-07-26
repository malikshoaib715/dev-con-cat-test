module Seeds
  # Policy as data. Cost comes from the fixtures; criticality decides fail-open
  # vs fail-closed when a layer cannot answer; default_weights are the score
  # deltas the consensus engine applies per signal.
  module LayerDefinitions
    # Compliance layers fail CLOSED: an unproven consent or an unchecked DNC
    # status can never be presented as a pass. Everything else fails OPEN so one
    # flaky vendor cannot bury a good lead.
    CRITICALITY = {
      "trustedform" => "required",
      "dnc" => "required",
      "blacklist_alliance" => "required",
      "duplicate_detection" => "required",
      "vpn_proxy" => "optional",
      "anura" => "optional",
      "phone_validation" => "optional",
      "email_validation" => "optional",
      "enrichment" => "optional",
      "voice" => "optional"
    }.freeze

    HARD_STOP_CAPABLE = %w[blacklist_alliance dnc trustedform anura duplicate_detection].freeze

    # Signal name => score delta from a starting 100. Named signals, not magic
    # numbers scattered through the engine: a buyer can retune any of these
    # without a deploy.
    DEFAULT_WEIGHTS = {
      "vpn_proxy" => {
        "anonymizing_network" => -25,
        "visit_ip_mismatch" => -10,
        "risk_medium" => -5
      },
      "anura" => {
        "suspect" => -15,
        "suspect_anonymizer" => -35,
        "suspect_fraud_farm" => -50
      },
      "trustedform" => {},
      "blacklist_alliance" => {
        "suspected" => -25
      },
      # A closed callback window is a timing problem, not a compliance one: it is
      # surfaced to whoever works the lead and costs nothing. Weighted at zero
      # explicitly rather than omitted, so every signal a processor can emit has a
      # defined weight and a typo cannot hide as "no weight found".
      "dnc" => {
        "window_closed" => 0
      },
      "phone_validation" => {
        "consensus_invalid" => -30,
        "providers_disagree" => -20,
        "consensus_voip" => -15,
        "line_type_split" => -5
      },
      # `unreachable_address` weighs what `both_undeliverable` weighs: it is the
      # same finding — mail cannot be delivered — reached from the address itself
      # rather than from two vendors agreeing about it.
      "email_validation" => {
        "both_undeliverable" => -35,
        "unreachable_address" => -35,
        "disposable" => -25,
        "providers_split" => -15
      },
      "enrichment" => {
        "no_match_to_lead" => -20,
        "sources_disagree" => -12
      },
      "duplicate_detection" => {
        "soft_duplicate" => -10
      },
      "voice" => {
        "reused_actor" => -50,
        "synthetic" => -50
      }
    }.freeze

    def self.load!
      costs = MockData.read("accounts.json").fetch("module_costs_in_credits")

      Layers::Registry.entries.each do |entry|
        definition = LayerDefinition.find_or_initialize_by(key: entry.key)
        definition.update!(
          name: entry.label,
          position: entry.position,
          cost_credits: costs.fetch(entry.key),
          criticality: CRITICALITY.fetch(entry.key),
          hard_stop_capable: HARD_STOP_CAPABLE.include?(entry.key),
          default_weights: DEFAULT_WEIGHTS.fetch(entry.key)
        )
      end

      puts "  layer_definitions: #{LayerDefinition.count}"
    end
  end
end
