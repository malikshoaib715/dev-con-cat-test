# frozen_string_literal: true

module Pixels
  # Builds the one line a buyer pastes into their <head>.
  #
  # A plain value builder rather than an ApplicationService: there is no domain
  # decision here and so nothing to report, and wrapping a formatter in a Result
  # would promise a failure that cannot happen.
  #
  # The base URL is passed in rather than read from the request, so this can be
  # called from a spec, a mailer, or a rake task as easily as from a controller.
  #
  # Async, because a tag in somebody else's <head> must never hold up their page.
  class SnippetGenerator
    def self.call(pixel:, endpoint_base:)
      new(pixel: pixel, endpoint_base: endpoint_base).call
    end

    def initialize(pixel:, endpoint_base:)
      @pixel = pixel
      @endpoint_base = endpoint_base.to_s.chomp("/")
    end

    def call
      %(<script async src="#{@endpoint_base}/super-pixel.js" ) +
        %(data-pixel-id="#{@pixel.public_id}" ) +
        %(data-pixel-key="#{@pixel.public_key}" ) +
        %(data-endpoint="#{@endpoint_base}/api/pixel"></script>)
    end
  end
end
