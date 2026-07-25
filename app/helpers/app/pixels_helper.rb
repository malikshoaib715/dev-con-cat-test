# frozen_string_literal: true

module App
  module PixelsHelper
    # What one verification through this pixel bills, from the same per-layer
    # costs the reservation charges — a buyer reading this number and a buyer
    # reading their ledger are looking at the same arithmetic.
    #
    # The costs are passed in already loaded so a list of pixels needs one query
    # for all of them.
    def cost_per_run(pixel, layer_costs)
      pixel.effective_layer_keys.sum { |layer_key| layer_costs.fetch(layer_key, 0) }
    end
  end
end
