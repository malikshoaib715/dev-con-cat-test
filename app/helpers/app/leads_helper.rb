# frozen_string_literal: true

module App
  module LeadsHelper
    # What the CRM filter bar offers. Every option comes from the vocabulary its
    # producer owns — the model's enums, the consensus engine's flags — so the
    # filter cannot drift into offering something the pipeline never writes.
    def lead_filter_fields
      [
        { name: :q, type: :text, label: "Search", placeholder: "Name, email or phone" },
        { name: :verdict, type: :select, label: "Verdict", options: humanized(Lead::VERDICTS) },
        { name: :status, type: :select, label: "Status", options: humanized(Lead::STATUSES) },
        { name: :flag, type: :select, label: "Flag", options: humanized(Consensus::Engine::FLAGS) },
        { name: :from, type: :date, label: "From" },
        { name: :to, type: :date, label: "To" }
      ]
    end

    # A layer that moved the score says by how much; one that agreed with the
    # starting hundred has nothing to report.
    def layer_score_delta(layer_result)
      delta = layer_result.score_delta.to_i
      delta.zero? ? "—" : delta
    end

    def layer_duration(layer_result)
      return "—" if layer_result.started_at.nil? || layer_result.completed_at.nil?

      "#{((layer_result.completed_at - layer_result.started_at) * 1000).round} ms"
    end

    def flag_chips(flags)
      safe_join(Array(flags).map { |flag| flag_chip(flag) }, " ")
    end

    private

    def humanized(values)
      values.map { |value| [ value.humanize, value ] }
    end

    def flag_chip(flag)
      tag.span flag.humanize,
               class: "inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 " \
                      "text-xs font-medium text-slate-600"
    end
  end
end
