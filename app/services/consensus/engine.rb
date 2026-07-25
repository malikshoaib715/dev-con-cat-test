# frozen_string_literal: true

module Consensus
  # Ten layers disagree; this decides. It reads a finished run and returns a
  # decision — it persists nothing, broadcasts nothing, and knows nothing about
  # certificates or credits. Verification::Finalizer owns all of that, which is
  # what keeps the rules testable without a database and re-runnable against a
  # historical policy.
  #
  # Three rules, in order of authority:
  #
  #   1. a hard stop ends it — no score outweighs unprovable consent;
  #   2. otherwise every layer that answered moves a score that starts at 100;
  #   3. a *required* layer that could not answer caps the result at review,
  #      because a compliance gap is never something to auto-accept through.
  class Engine
    Decision = Data.define(:verdict, :score, :reasons, :flags, :hard_stop_layer,
                           :per_layer_deltas, :policy_snapshot)

    # A layer that errored, and whether its silence is allowed to be fatal.
    Unavailable = Data.define(:layer_key, :required)

    HARD_STOP_SCORE = 0
    EXACT_DUPLICATE = "exact_duplicate"

    DUPLICATE_FLAG            = "duplicate"
    SOFT_DUPLICATE_FLAG       = "soft_duplicate"
    REQUIRED_UNAVAILABLE_FLAG = "required_layer_unavailable"

    # The whole flag vocabulary, so the CRM's filter offers exactly what the
    # engine can produce rather than a hand-kept list beside it.
    FLAGS = [ DUPLICATE_FLAG, SOFT_DUPLICATE_FLAG, REQUIRED_UNAVAILABLE_FLAG ].freeze

    def self.call(run:, policy:)
      new(run: run, policy: policy).call
    end

    def initialize(run:, policy:)
      @run = run
      @policy = policy
    end

    def call
      Decision.new(
        verdict: verdict,
        score: score,
        reasons: reasons,
        flags: flags,
        hard_stop_layer: stop&.layer_key,
        per_layer_deltas: scoring.per_layer_deltas,
        policy_snapshot: @policy.snapshot
      )
    end

    private

    def verdict
      return "reject" if stop

      capped(banded)
    end

    def score
      stop ? HARD_STOP_SCORE : scoring.score
    end

    def banded
      return "accept" if scoring.score >= @policy.accept_threshold
      return "review" if scoring.score >= @policy.review_threshold

      "reject"
    end

    # A compliance layer that could not answer is not evidence of a good lead. The
    # lead is not destroyed for it either — it goes to a human.
    #
    # Nothing answering at all is capped for the same reason and a stronger one:
    # a score of 100 there means "no check found anything", which is indis-
    # tinguishable from "no check ran". Failing open is one flaky vendor not
    # burying a good lead; it is not a certificate that attests to nothing.
    def capped(banded_verdict)
      return banded_verdict unless banded_verdict == "accept"
      return "review" if required_unavailable? || nothing_answered?

      banded_verdict
    end

    def nothing_answered?
      scoring.contributions.empty?
    end

    def reasons
      ReasonBuilder.call(stop: stop, penalties: scoring.penalties, unavailable: unavailable,
                         answered: !nothing_answered?)
    end

    def flags
      [
        (DUPLICATE_FLAG if duplicate_stop?),
        (SOFT_DUPLICATE_FLAG if soft_duplicate?),
        (REQUIRED_UNAVAILABLE_FLAG if required_unavailable?)
      ].compact
    end

    def stop
      return @stop if defined?(@stop)

      @stop = HardStopEvaluator.call(rows: rows, policy: @policy)
    end

    def scoring
      @scoring ||= SignalScorer.call(rows: rows, policy: @policy)
    end

    def unavailable
      @unavailable ||= rows.select { |row| row.status == "errored" }
                           .map { |row| Unavailable.new(layer_key: row.layer_key, required: @policy.required?(row.layer_key)) }
    end

    def required_unavailable?
      unavailable.any?(&:required)
    end

    def duplicate_stop?
      stop&.verdict == EXACT_DUPLICATE
    end

    def soft_duplicate?
      scoring.contributions.any? { |contribution| contribution.signals.include?(SOFT_DUPLICATE_FLAG) }
    end

    # Registry order, not row order: which vendor answered first must not change
    # which reason a buyer is given.
    def rows
      @rows ||= @run.layer_results.to_a.sort_by { |row| Layers::Registry.fetch(row.layer_key).position }
    end
  end
end
