# frozen_string_literal: true

module Verification
  # Decides whether a run has finished and, if it has, hands exactly one caller the
  # right to finalize it.
  #
  # Ten layer jobs race each other. Two of them finishing at the same instant both
  # see no outstanding work, so without an atomic claim the run would be finalized
  # twice — two certificates issued, credits settled twice. The conditional UPDATE
  # below is the whole point of this class: exactly one caller can move a run out
  # of a non-final state, and only that caller is told to go on.
  class CompletionGate < ApplicationService
    CLAIMABLE_FROM = %w[pending running].freeze

    def initialize(run:)
      @run = run
    end

    def call
      return failure("layers still outstanding", code: :outstanding) if outstanding_layers?
      return failure("another worker is already finalizing this run", code: :already_claimed) unless claimed?

      success(@run)
    end

    private

    def outstanding_layers?
      @run.layer_results.outstanding.exists?
    end

    # `update_all` deliberately skips callbacks and validations: it has to compile
    # to one conditional UPDATE, because the condition *is* the lock.
    #
    # `pending` is claimable alongside `running` on purpose — layers can finish
    # before the dispatcher's flip to `running` has landed, and a run whose work is
    # done must never be stranded on a technicality about which state it is in.
    def claimed?
      VerificationRun.where(id: @run.id, status: CLAIMABLE_FROM)
                     .update_all(status: "finalizing", updated_at: Time.current) == 1
    end
  end
end
