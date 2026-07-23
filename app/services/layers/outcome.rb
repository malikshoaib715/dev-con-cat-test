# frozen_string_literal: true

module Layers
  # What a processor decided about one layer. A value, not a record: the job that
  # called the processor is what persists it.
  #
  # `verdict` is the layer's own primary answer, in the vendor's vocabulary
  # ("dnc_listed", "suspect_fraud_farm"). `signals` is the full set of weighted
  # signal names the consensus engine should score, and every one of them must
  # exist as a key in that layer's `default_weights` — the engine looks weights up
  # by exactly these strings.
  Outcome = Data.define(:status, :verdict, :panel_verdict, :detail, :signals, :raw_response) do
    def not_applicable?
      status == "not_applicable"
    end
  end
end
