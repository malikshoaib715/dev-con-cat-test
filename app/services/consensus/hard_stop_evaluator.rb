# frozen_string_literal: true

module Consensus
  # Finds the one answer that ends the verification regardless of everything else:
  # unprovable consent, a number that cannot legally be dialled, a confirmed
  # litigator, a confirmed bot, a person this buyer has already paid for.
  #
  # Layers are examined in registry order rather than whatever order the rows came
  # back in, so a lead that trips two stops always names the same one. A verdict a
  # buyer has to explain must not depend on which vendor answered first.
  class HardStopEvaluator
    Stop = Data.define(:layer_key, :verdict, :detail)

    def self.call(rows:, policy:)
      stopped = rows.find { |row| stops?(row, policy) }
      return nil if stopped.nil?

      Stop.new(layer_key: stopped.layer_key, verdict: stopped.verdict, detail: stopped.detail)
    end

    # Only a layer that actually answered can stop a lead. A layer that errored is
    # unavailability, which is a different rule (see Consensus::Engine).
    def self.stops?(row, policy)
      row.status == "completed" && policy.hard_stop?(row.layer_key, row.verdict)
    end
    private_class_method :stops?
  end
end
