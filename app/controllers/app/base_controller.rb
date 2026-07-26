# frozen_string_literal: true

module App
  # The account dashboard. Everything here is loaded through `current_account`
  # associations as well as acts_as_tenant, so isolation survives a
  # misconfigured gem.
  class BaseController < ApplicationController
    before_action :require_account

    # Conditioned on the action name rather than declared with `only:`, because
    # not every controller in this namespace has an index — a singular resource
    # would otherwise fail on a callback naming an action it does not define.
    after_action :verify_authorized,    unless: :listing?
    after_action :verify_policy_scoped, if:     :listing?

    private

    def listing?
      action_name == "index"
    end

    def current_account
      current_user.account
    end
    helper_method :current_account

    # A super_admin has no tenant of their own; the platform view lives at /admin.
    def require_account
      render_not_found if current_account.nil?
    end
  end
end
