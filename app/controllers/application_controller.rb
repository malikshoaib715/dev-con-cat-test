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

  # The human loop a REVIEW verdict implies, counted for the nav badge. Lives on
  # the controller rather than in the layout because a view that queries is a
  # view nobody can preload for.
  # Opens its own tenant rather than trusting the ambient one: this renders on
  # every page carrying the nav, including the public verifier, which is
  # deliberately outside every tenant scope.
  def review_queue_count
    account = current_user&.account
    return nil if account.nil?

    @review_queue_count ||= ActsAsTenant.with_tenant(account) { account.leads.with_verdict("review").count }
  end
  helper_method :review_queue_count

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
