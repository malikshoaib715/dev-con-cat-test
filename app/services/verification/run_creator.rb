# frozen_string_literal: true

module Verification
  # Creates a run and, with it, one row per layer in the registry — including the
  # layers this account never bought.
  #
  # Pre-creating all ten is what makes the three states the rubric cares about
  # first-class from the moment a lead arrives: a layer nobody bought is
  # `not_enabled`, a layer that will report is `pending`, and neither is inferred
  # later from a row's absence. It also gives the live panel its skeleton rows and
  # turns job idempotency into a row-level compare-and-set.
  class RunCreator < ApplicationService
    NOT_ENABLED_DETAIL = "not included in this account's plan"

    def initialize(lead:, effective_layer_keys:)
      @lead = lead
      @effective_layer_keys = effective_layer_keys
    end

    def call
      run = @lead.create_verification_run!(account: @lead.account, status: "pending")
      Layers::Registry.keys.each { |layer_key| create_layer_result(run, layer_key) }

      success(run)
    end

    private

    def create_layer_result(run, layer_key)
      run.layer_results.create!(account: run.account, layer_key: layer_key, **initial_state(layer_key))
    end

    # A layer outside the account's plan is finished before it starts, and says so
    # rather than being left blank.
    def initial_state(layer_key)
      return { status: "pending" } if @effective_layer_keys.include?(layer_key)

      { status: "not_enabled", panel_verdict: "skip", detail: NOT_ENABLED_DETAIL, completed_at: Time.current }
    end
  end
end
