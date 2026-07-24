# frozen_string_literal: true

module Consensus
  # Turns the signals the layers reported into a score out of 100.
  #
  # Only layers that answered are scored. A layer the buyer never bought, and a
  # layer that had nothing to judge, contribute nothing and appear in no reason —
  # a lead is never penalised for a check that was never going to run.
  class SignalScorer
    STARTING_SCORE = 100
    SCORE_RANGE = (0..100).freeze

    # One per layer that answered, carrying what it costs the lead and the sentence
    # a human should read for it.
    Contribution = Data.define(:layer_key, :signals, :detail, :delta)

    Scoring = Data.define(:score, :contributions) do
      def per_layer_deltas
        contributions.to_h { |contribution| [ contribution.layer_key, contribution.delta ] }
      end

      def penalties
        contributions.reject { |contribution| contribution.delta.zero? }
      end
    end

    def self.call(rows:, policy:)
      new(rows: rows, policy: policy).call
    end

    def initialize(rows:, policy:)
      @rows = rows
      @policy = policy
    end

    def call
      Scoring.new(score: score, contributions: contributions)
    end

    private

    def score
      (STARTING_SCORE + contributions.sum(&:delta)).clamp(SCORE_RANGE)
    end

    def contributions
      @contributions ||= @rows.select { |row| row.status == "completed" }.map { |row| contribution_for(row) }
    end

    def contribution_for(row)
      signals = signals_for(row)

      Contribution.new(
        layer_key: row.layer_key,
        signals: signals,
        detail: row.detail,
        delta: signals.sum { |signal| @policy.weight_for(row.layer_key, signal) }
      )
    end

    # The processors record what they want scored alongside the vendor's answer, so
    # this reads one place. The fallback covers a row written before signals were
    # recorded: its own verdict is the best available description of what it found.
    def signals_for(row)
      Array(row.raw_response.fetch("signals") { [ row.verdict ].compact })
    end
  end
end
