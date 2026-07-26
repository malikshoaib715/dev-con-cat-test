# frozen_string_literal: true

module Layers
  # One processor per layer, each answering exactly one question about a lead.
  #
  # A processor reads its vendor payload and decides; it does not persist, audit,
  # broadcast, or know that a verification run exists. That keeps every layer's
  # rules readable on their own and unit-testable without a pipeline.
  #
  # Two of the six LayerResult states are deliberately not a processor's to
  # return: `not_enabled` was settled at ingestion, before any processor ran, and
  # `errored` is the job's judgement about an exception, not a verdict.
  class BaseProcessor
    def self.call(lead:)
      new(lead: lead).call
    end

    # Derived from the registry rather than declared per class, so a processor and
    # its canonical key cannot drift apart.
    def self.layer_key
      @layer_key ||= Registry.entries.find { |entry| entry.processor_name == name }&.key ||
                     raise(ArgumentError, "#{name} is not registered in Layers::Registry")
    end

    def initialize(lead:)
      @lead = lead
    end

    # The one sanctioned NotImplementedError in the codebase: this is the contract
    # every processor exists to fill.
    def call
      raise NotImplementedError, "#{self.class.name} must implement #call and return a Layers::Outcome"
    end

    private

    attr_reader :lead

    def payload
      @payload ||= Providers::Gateway.fetch(layer_key: self.class.layer_key, lead: lead)
    end

    def completed(verdict:, panel_verdict:, detail:, signals: [])
      Outcome.new(
        status: "completed",
        verdict: verdict,
        panel_verdict: panel_verdict,
        detail: detail,
        signals: signals,
        raw_response: raw_response
      )
    end

    # The three layers that are phone lookups share one precondition: there has to
    # be a number to look up. A lead may legitimately arrive with only an email
    # (ingestion requires one identity, not both), and every vendor fixture here
    # answers about an identity rather than refusing an unusable one — so without
    # this guard a lead whose "phone" is punctuation collects three clean passes
    # and a certificate attesting to them.
    def dialable_phone?
      Leads::Normalizer.dialable?(lead.phone_normalized)
    end

    def no_dialable_phone
      not_applicable(detail: "no dialable phone number on the lead")
    end

    # The layer had nothing to judge — no voice sample, no identity to match. That
    # is not a pass and it is not a failure, and the certificate says so.
    def not_applicable(detail:)
      Outcome.new(
        status: "not_applicable",
        verdict: nil,
        panel_verdict: "skip",
        detail: detail,
        signals: [],
        raw_response: raw_response
      )
    end

    def raw_response
      payload
    end
  end
end
