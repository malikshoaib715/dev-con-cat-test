# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include RequestContext
  include Pundit::Authorization

  allow_browser versions: :modern
  stale_when_importmap_changes

  before_action :authenticate_user!
  before_action :set_current_tenant

  # A cross-tenant record is reported as missing, never as forbidden: 403 would
  # confirm that somebody else's lead exists.
  rescue_from ActiveRecord::RecordNotFound,      with: :render_not_found
  rescue_from ActsAsTenant::Errors::NoTenantSet, with: :render_not_found
  rescue_from Pundit::NotAuthorizedError,        with: :render_forbidden

  private

  def set_current_tenant
    Current.user = current_user
    Current.account = current_user&.account
    ActsAsTenant.current_tenant = current_user&.account
  end

  def render_not_found
    render "errors/not_found", status: :not_found, formats: [ :html ]
  end

  def render_forbidden
    render "errors/forbidden", status: :forbidden, formats: [ :html ]
  end
end
