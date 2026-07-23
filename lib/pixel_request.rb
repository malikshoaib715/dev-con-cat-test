# frozen_string_literal: true

# Recognises a call to the public pixel surface from a raw Rack request. The
# throttle middleware runs long before the controller stack, so the header name
# and the path prefix live here rather than being spelled twice.
module PixelRequest
  PATH_PREFIX = "/api/pixel"
  KEY_HEADER = "X-Pixel-Key"
  RACK_KEY_HEADER = "HTTP_X_PIXEL_KEY"

  def self.path?(path)
    path.to_s.start_with?(PATH_PREFIX)
  end

  def self.public_key(request)
    request.get_header(RACK_KEY_HEADER).presence
  end
end
