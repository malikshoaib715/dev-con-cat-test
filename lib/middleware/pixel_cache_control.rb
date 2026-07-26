# frozen_string_literal: true

# The pixel is the one file in `public/` that is not content-addressed.
#
# Everything else under there is either digested by the asset pipeline or
# incidental, so the long `public_file_server` max-age is right for them: a
# digested name changes when its content does. `super-pixel.js` keeps its name
# forever — it is the URL inside every buyer's snippet — so that same header
# means a browser which fetched it once will not ask again for a year, and a
# fix to the script reaches nobody who has already loaded a buyer's page.
#
# Revalidation instead: cached, but re-checked, so a corrected pixel is one
# conditional GET away rather than one cache expiry away. `ActionDispatch::Static`
# takes no per-path configuration, so the header is corrected on the way out.
class PixelCacheControl
  PATH = "/super-pixel.js"
  POLICY = "public, max-age=300, must-revalidate"

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    headers["cache-control"] = POLICY if env["PATH_INFO"] == PATH

    [ status, headers, body ]
  end
end
