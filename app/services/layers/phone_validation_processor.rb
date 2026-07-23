# frozen_string_literal: true

module Layers
  # Three independent providers look the number up. One provider is an opinion;
  # agreement is a signal — so this layer reports on the *consensus*, never on any
  # single vendor's answer.
  #
  # The distinction that matters most here: three providers agreeing the number is
  # a VoIP line is not the same as three providers disagreeing about whether it is
  # real. The first is a fact about the number, the second is doubt about the data.
  class PhoneValidationProcessor < BaseProcessor
    VOIP = "voip"
    DISSENT_THRESHOLD = 2

    def call
      return no_provider_answers if providers.empty?
      return consensus_invalid if invalid_providers.size >= DISSENT_THRESHOLD
      return providers_disagree if invalid_providers.any?
      return consensus_voip if line_types == [ VOIP ]
      return line_type_split if line_types.size > 1

      completed(
        verdict: "valid_consensus",
        panel_verdict: "pass",
        detail: "#{tally} providers valid #{line_types.first}"
      )
    end

    private

    # A vendor that returned no provider answers has not judged this number. That
    # is a check which did not run, not a number that passed — reporting it as a
    # valid consensus would put a cleared check on the certificate on the strength
    # of an empty payload.
    def no_provider_answers
      not_applicable(detail: "no provider responses")
    end

    def consensus_invalid
      completed(
        verdict: "consensus_invalid",
        panel_verdict: "fail",
        detail: "#{invalid_providers.size}/#{providers.size} providers say the number is invalid",
        signals: [ "consensus_invalid" ]
      )
    end

    # Naming the dissenter is the point: a buyer wants to know which vendor to
    # doubt, not just that somebody disagreed.
    def providers_disagree
      completed(
        verdict: "providers_disagree",
        panel_verdict: "warn",
        detail: "providers disagree — #{tell(invalid_providers, 'invalid')}, #{tell(valid_providers, 'valid')}",
        signals: [ "providers_disagree" ]
      )
    end

    def tell(names, opinion)
      "#{names.to_sentence} #{names.one? ? 'says' : 'say'} #{opinion}"
    end

    # Agreement on VoIP: the number is real but it is a disposable app line, which
    # is a cheaper thing to obtain than a mobile contract.
    def consensus_voip
      completed(
        verdict: "consensus_voip",
        panel_verdict: "warn",
        detail: "#{tally} valid — all VoIP#{carriers_detail}",
        signals: [ "consensus_voip" ]
      )
    end

    # Everyone agrees it is real and nobody agrees what it is. Weak, but worth
    # showing.
    def line_type_split
      completed(
        verdict: "line_type_split",
        panel_verdict: "warn",
        detail: "#{tally} valid, line types differ (#{line_types.join(', ')})",
        signals: [ "line_type_split" ]
      )
    end

    def providers
      @providers ||= payload.fetch("providers", {})
    end

    # Sorted, not left in the order the payload happened to arrive in: jsonb does
    # not preserve key order, so a seeded response and a clean default would
    # otherwise produce differently worded details for the same finding.
    def invalid_providers
      @invalid_providers ||= providers.reject { |_name, answer| answer["valid"] }.keys.sort
    end

    def valid_providers
      @valid_providers ||= providers.select { |_name, answer| answer["valid"] }.keys.sort
    end

    def line_types
      @line_types ||= providers.values.filter_map { |answer| answer["line_type"] }.uniq.sort
    end

    def tally
      "#{valid_providers.size}/#{providers.size}"
    end

    def carriers_detail
      carriers = providers.values.filter_map { |answer| answer["carrier"] }.uniq
      return "" if carriers.empty?

      " (#{carriers.join(', ')})"
    end
  end
end
