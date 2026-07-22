# frozen_string_literal: true

# Authentication is audited from Warden's own hooks rather than a controller, so
# every path into and out of a session is covered — including the ones Devise
# handles without our code running.
Rails.application.config.to_prepare do
  Warden::Manager.after_authentication do |user, _auth, _options|
    Audit::Recorder.record!(
      Audit::Events::AUTH_LOGIN_SUCCEEDED,
      subject: user, actor: user, account: user.account
    )
  end

  Warden::Manager.before_logout do |user, _auth, _options|
    next if user.nil?

    Audit::Recorder.record!(
      Audit::Events::AUTH_LOGOUT,
      subject: user, actor: user, account: user.account
    )
  end

  # Warden has already rewritten PATH_INFO to the failure action by this point,
  # so the originally attempted path comes from the options it hands us.
  Warden::Manager.before_failure do |env, options|
    request = ActionDispatch::Request.new(env)
    next unless LoginAttempt.submission?(request, path: options[:attempted_path])

    Current.request_id ||= request.request_id
    Current.ip_address ||= request.remote_ip
    Audit::Recorder.record!(
      Audit::Events::AUTH_LOGIN_FAILED,
      payload: { email: LoginAttempt.submitted_email(request) }
    )
  end
end
