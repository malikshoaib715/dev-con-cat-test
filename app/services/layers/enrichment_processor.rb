# frozen_string_literal: true

module Layers
  # Two enrichment sources append an identity to the lead. Two sources exist so
  # they can be cross-validated: when they agree the record is deep, and when they
  # disagree with each other — or with the name the visitor typed — that is the
  # signal.
  #
  # Failing to cross-validate is one signal with two shapes: the sources returned
  # different people, or only one of them found a person at all. Both weigh the
  # same, and both are reported in the words that describe what happened.
  class EnrichmentProcessor < BaseProcessor
    SOURCES = { "audiencelabs" => "AudienceLabs", "bytemine" => "ByteMine" }.freeze
    CROSS_VALIDATED_FIELDS = { "address" => "address", "age_band" => "age band" }.freeze
    DISAGREEMENT_SIGNAL = "sources_disagree"

    def call
      return no_match_to_lead if nobody_matched_the_lead?
      return single_source_only if unresolved_sources.any?
      return sources_disagree if differing_fields.any?

      completed(
        verdict: "match",
        panel_verdict: "pass",
        detail: "#{SOURCES.size} sources agree, identity matches"
      )
    end

    private

    def no_match_to_lead
      completed(
        verdict: "no_match_to_lead",
        panel_verdict: "warn",
        detail: "neither source could match this identity to the lead",
        signals: [ "no_match_to_lead" ]
      )
    end

    # One source found a person and the other found nothing, so there is nothing to
    # cross-validate against — coverage without corroboration.
    def single_source_only
      completed(
        verdict: DISAGREEMENT_SIGNAL,
        panel_verdict: "warn",
        detail: "only #{resolved_sources.to_sentence} could resolve this identity — single-source coverage",
        signals: [ DISAGREEMENT_SIGNAL ]
      )
    end

    def sources_disagree
      completed(
        verdict: DISAGREEMENT_SIGNAL,
        panel_verdict: "warn",
        detail: "#{SOURCES.values.to_sentence} disagree on #{differing_fields.to_sentence}",
        signals: [ DISAGREEMENT_SIGNAL ]
      )
    end

    def answers
      @answers ||= SOURCES.keys.to_h { |source| [ source, payload.fetch(source, {}) ] }
    end

    def nobody_matched_the_lead?
      answers.values.none? { |answer| answer["match_to_lead"] }
    end

    def unresolved_sources
      @unresolved_sources ||= answers.filter_map { |source, answer| SOURCES.fetch(source) if answer["matched"] == false }
    end

    def resolved_sources
      SOURCES.values - unresolved_sources
    end

    def differing_fields
      @differing_fields ||= CROSS_VALIDATED_FIELDS.filter_map do |field, label|
        label if answers.values.map { |answer| answer[field] }.uniq.size > 1
      end
    end
  end
end
