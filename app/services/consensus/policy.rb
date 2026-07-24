# frozen_string_literal: true

module Consensus
  # The rules one account is judged by, resolved once and then frozen onto the
  # verdict that used them.
  #
  # A query, not a command: nothing here mutates, so it is a plain value object
  # rather than an ApplicationService. The engine asks it what a signal is worth,
  # what stops a lead outright, and where the bands sit — and never reads a
  # weight, a threshold or a stop condition from anywhere else.
  #
  # Everything except the default stop conditions is data. A buyer who wants a
  # suspected litigator refused rather than reviewed flips `treat_as_hard_stop`
  # on their own layer policy; nobody deploys anything.
  class Policy
    ENGINE_VERSION = "1.0"

    DEFAULT_ACCEPT_THRESHOLD = 70
    DEFAULT_REVIEW_THRESHOLD = 40

    # The verdict strings — the vendors' own vocabulary, as the processors record
    # them — that end a verification on the spot. Consent that cannot be proven, a
    # number that cannot legally be dialled, a confirmed litigator, a confirmed
    # bot, or a person this buyer has already paid for.
    DEFAULT_HARD_STOPS = {
      "anura"               => %w[bad].freeze,
      "trustedform"         => %w[mismatch expired not_found].freeze,
      "blacklist_alliance"  => %w[litigator].freeze,
      "dnc"                 => %w[dnc_listed internal_dnc].freeze,
      "duplicate_detection" => %w[exact_duplicate].freeze
    }.freeze

    def self.for(account:)
      new(account: account, definitions: LayerDefinition.ordered.to_a, overrides: account.layer_policies.to_a)
    end

    def initialize(account:, definitions:, overrides:)
      @account = account
      @definitions = definitions.index_by(&:key)
      @overrides = overrides.index_by(&:layer_key)
    end

    # A signal nobody weighted is worth nothing, deliberately: `window_closed` is
    # emitted by the DNC processor so a human sees it, and weighted at zero so it
    # never costs the lead a point. A missing weight must therefore read as zero
    # rather than raise.
    def weight_for(layer_key, signal)
      weights_for(layer_key).fetch(signal, 0)
    end

    # Coerced on the way out because both sides come from jsonb, where a buyer's
    # override can hold a string, a float, or a null. A weight that is not a whole
    # number of points is meaningless to the score, and letting one reach the
    # scorer would take a verification down with a TypeError rather than costing
    # the lead nothing — which is what an undefined weight already means.
    def weights_for(layer_key)
      @weights_for ||= {}
      @weights_for[layer_key] ||= default_weights(layer_key)
                                  .merge(weight_overrides(layer_key))
                                  .transform_values { |delta| Integer(delta, exception: false) || 0 }
    end

    def hard_stop?(layer_key, verdict)
      return false if verdict.blank?

      hard_stops_for(layer_key).include?(verdict)
    end

    # Promotion, in one sentence: turning on `treat_as_hard_stop` makes every
    # signal this layer penalises a lead for into a refusal. It touches that layer
    # and no other.
    def hard_stops_for(layer_key)
      stops = DEFAULT_HARD_STOPS.fetch(layer_key, [])
      return stops unless promoted?(layer_key)

      (stops + penalising_signals(layer_key)).uniq
    end

    # A required layer that could not answer caps the verdict at review; an
    # optional one is allowed to fail open.
    def required?(layer_key)
      definition(layer_key)&.required? || false
    end

    def accept_threshold
      threshold(@account.accept_threshold_override, DEFAULT_ACCEPT_THRESHOLD)
    end

    def review_threshold
      threshold(@account.review_threshold_override, DEFAULT_REVIEW_THRESHOLD)
    end

    # Copied onto every verdict, so "why was this rejected?" stays answerable
    # years later even after the buyer has retuned everything.
    def snapshot
      {
        "engine_version" => ENGINE_VERSION,
        "thresholds" => { "accept" => accept_threshold, "review" => review_threshold },
        "layers" => Layers::Registry.keys.index_with { |layer_key| layer_snapshot(layer_key) }
      }
    end

    private

    def layer_snapshot(layer_key)
      {
        "weights" => weights_for(layer_key),
        "hard_stops" => hard_stops_for(layer_key),
        "criticality" => definition(layer_key)&.criticality
      }
    end

    def penalising_signals(layer_key)
      weights_for(layer_key).select { |_signal, delta| delta.negative? }.keys
    end

    def promoted?(layer_key)
      @overrides[layer_key]&.treat_as_hard_stop || false
    end

    def default_weights(layer_key)
      definition(layer_key)&.default_weights || {}
    end

    def weight_overrides(layer_key)
      @overrides[layer_key]&.weight_overrides || {}
    end

    def definition(layer_key)
      @definitions[layer_key]
    end

    # Integer(), not to_i: settings is jsonb with no interface guarding it yet, and
    # "abc".to_i is 0 — which is truthy, so the default never applies and an accept
    # threshold of zero accepts every lead that escapes a hard stop. A value that
    # does not parse as a whole number is treated as not set.
    def threshold(override, default)
      Integer(override, exception: false) || default
    end
  end
end
