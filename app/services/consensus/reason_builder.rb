# frozen_string_literal: true

module Consensus
  # The sentences a human reads on the lead page, in the certificate, and in the
  # answer to "why was this rejected?".
  #
  # Ordered by how much each layer actually moved the verdict, because the first
  # line is the one anybody reads. A layer that cost nothing says nothing.
  class ReasonBuilder
    CLEAN = "all enabled layers passed"
    NOTHING_ANSWERED = "no layer returned a verdict — verdict capped at review"

    def self.call(stop:, penalties:, unavailable:, answered:, unjudged: [])
      new(stop: stop, penalties: penalties, unavailable: unavailable, answered: answered,
          unjudged: unjudged).call
    end

    def initialize(stop:, penalties:, unavailable:, answered:, unjudged: [])
      @stop = stop
      @penalties = penalties
      @unavailable = unavailable
      @answered = answered
      @unjudged = unjudged
    end

    def call
      leading_reasons + unavailability_notes + unjudged_notes
    end

    private

    def leading_reasons
      return [ hard_stop_reason ] if @stop
      # "Everything passed" and "nothing ran" both produce an empty penalty list
      # and must never read the same way.
      return [ NOTHING_ANSWERED ] unless @answered
      return [ CLEAN ] if @penalties.empty? && @unavailable.empty? && @unjudged.empty?

      ranked_penalties.map { |penalty| penalty_reason(penalty) }
    end

    def hard_stop_reason
      "hard stop — #{label(@stop.layer_key)}: #{@stop.detail}"
    end

    def penalty_reason(penalty)
      "#{label(penalty.layer_key)}: #{penalty.detail} (#{format_delta(penalty.delta)})"
    end

    # Largest effect first; registry order breaks ties so the same lead always
    # reads the same way.
    def ranked_penalties
      @penalties.sort_by { |penalty| [ -penalty.delta.abs, position(penalty.layer_key) ] }
    end

    # An unavailable layer is always said out loud, whichever way it failed. A
    # certificate that quietly omitted a check nobody ran would be the exact
    # misrepresentation these records exist to prevent.
    def unavailability_notes
      @unavailable.sort_by { |layer| position(layer.layer_key) }.map do |layer|
        next "required layer unavailable: #{layer.layer_key} — verdict capped at review" if layer.required

        "optional layer unavailable: #{layer.layer_key} — recorded, not counted as a pass"
      end
    end

    # Said out loud for the same reason an unavailable layer is, and worded so the
    # buyer can act on it: the check did not fail, it never got what it needed.
    def unjudged_notes
      @unjudged.sort_by { |layer| position(layer.layer_key) }.map do |layer|
        "#{label(layer.layer_key)} could not be checked: #{layer.detail} — verdict capped at review"
      end
    end

    def format_delta(delta)
      delta.negative? ? delta.to_s : "+#{delta}"
    end

    def label(layer_key)
      Layers::Registry.label(layer_key)
    end

    def position(layer_key)
      Layers::Registry.fetch(layer_key).position
    end
  end
end
