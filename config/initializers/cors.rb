# frozen_string_literal: true

# The pixel is embedded on buyers' own domains, so the browser has to be allowed
# to call us from anywhere: without this every real embed dies in preflight.
#
# A wildcard origin is not a tenancy hole. CORS governs browser mechanics only;
# the account binding comes from the pixel key (authentication) and the origin is
# then checked against that pixel's allowed_domains in the controller
# (authorization). Credentials stay off — the pixel carries a key, not a cookie,
# so there is no session for another site to ride.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"
    resource "/api/pixel/*",
             headers: :any,
             methods: %i[post get options],
             credentials: false,
             max_age: 600
  end
end
