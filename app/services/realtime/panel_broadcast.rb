# frozen_string_literal: true

module Realtime
  # The live panel on the buyer's landing page: one stream per lead, carrying the
  # frames the page already knows how to render (Realtime::PanelFrame).
  class PanelBroadcast
    def self.call(event:, lead:)
      frame = PanelFrame.for(event)
      return nil if frame.nil?

      ActionCable.server.broadcast(PanelFrame.stream_name(lead.public_id), frame)
    end
  end
end
