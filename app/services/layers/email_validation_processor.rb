# frozen_string_literal: true

module Layers
  # Two independent providers check the mailbox. As with the phone layer, the
  # interesting thing is whether they agree.
  #
  # Undeliverable is the heaviest signal but still not a hard stop: an address that
  # bounces makes a lead worth less, and consent was still given by whoever is on
  # the phone. The verdict is capped by the score, not vetoed.
  class EmailValidationProcessor < BaseProcessor
    def call
      return no_email_supplied if lead.email.blank?
      return unreachable_address unless deliverable_address?
      return no_provider_answers if providers.empty?
      return undeliverable if undeliverable?
      return disposable if disposable?
      return providers_split if split_on_deliverability?

      completed(verdict: "deliverable", panel_verdict: "pass", detail: "#{tally} deliverable")
    end

    private

    # No answers is not the same as two answers of "undeliverable", which is what
    # counting an empty payload would otherwise produce — the heaviest signal this
    # layer has, on no evidence at all.
    def no_provider_answers
      not_applicable(detail: "no provider responses")
    end

    # A lead that never offered an address is reachable by phone and owes this
    # layer nothing. Silence, not a penalty — the mirror of a missing voice
    # sample.
    def no_email_supplied
      not_applicable(detail: "no email address on the lead")
    end

    # An address that *was* given and cannot receive mail is a different thing:
    # not a check that could not run, but a finding this layer made on its own.
    # No provider is quoted for it, because none was asked and none is needed —
    # a domain with no dot has no mail exchanger anywhere on the internet. It
    # weighs what two providers agreeing on undeliverable weighs, since it is
    # the same fact arrived at with more certainty.
    def unreachable_address
      completed(
        verdict: "unreachable_address",
        panel_verdict: "warn",
        detail: "#{lead.email} cannot receive mail — no deliverable domain",
        signals: [ "unreachable_address" ]
      )
    end

    def deliverable_address?
      Leads::Normalizer.deliverable_shape?(lead.email)
    end

    # Both signals are emitted when both hold: an undeliverable address on a
    # throwaway domain is worse than either alone, and the engine should see both
    # rather than only the first rule that matched.
    def undeliverable
      completed(
        verdict: "both_undeliverable",
        panel_verdict: "warn",
        detail: [ "#{providers.size}/#{providers.size} undeliverable", disposable_detail ].compact.join(", "),
        signals: [ "both_undeliverable", disposable? ? "disposable" : nil ].compact
      )
    end

    def disposable
      completed(
        verdict: "disposable",
        panel_verdict: "warn",
        detail: "#{tally} deliverable, but on a disposable domain",
        signals: [ "disposable" ]
      )
    end

    def providers_split
      completed(
        verdict: "providers_split",
        panel_verdict: "warn",
        detail: "providers disagree — #{tell(undeliverable_providers, 'undeliverable')}, " \
                "#{tell(deliverable_providers, 'deliverable')}",
        signals: [ "providers_split" ]
      )
    end

    def tell(names, opinion)
      "#{names.to_sentence} #{names.one? ? 'says' : 'say'} #{opinion}"
    end

    def providers
      @providers ||= payload.fetch("providers", {})
    end

    # Sorted for the same reason as in the phone layer: jsonb key order is not the
    # order the vendor sent, so the wording must not depend on it.
    def undeliverable_providers
      @undeliverable_providers ||= providers.reject { |_name, answer| answer["deliverable"] }.keys.sort
    end

    def deliverable_providers
      @deliverable_providers ||= providers.select { |_name, answer| answer["deliverable"] }.keys.sort
    end

    def undeliverable?
      deliverable_providers.empty?
    end

    def split_on_deliverability?
      undeliverable_providers.any? && deliverable_providers.any?
    end

    def disposable?
      providers.any? && providers.values.all? { |answer| answer["disposable"] }
    end

    def disposable_detail
      "on a disposable domain" if disposable?
    end

    def tally
      "#{deliverable_providers.size}/#{providers.size}"
    end
  end
end
