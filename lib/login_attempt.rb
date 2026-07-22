# frozen_string_literal: true

# Recognises a sign-in submission from a raw Rack request. The throttle
# middleware and the audit hook both need this and they run at different points
# in the stack: Warden rewrites PATH_INFO before its failure callbacks fire, so
# the path has to be supplied explicitly there.
module LoginAttempt
  PATH = "/users/sign_in"

  def self.path?(path)
    path.to_s.split("?").first == PATH
  end

  def self.submission?(request, path: request.path)
    request.post? && path?(path)
  end

  def self.submitted_email(request)
    request.params.dig("user", "email").to_s.downcase.presence
  end
end
