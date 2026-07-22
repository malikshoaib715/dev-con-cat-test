# frozen_string_literal: true

module Admin
  # Platform operator surface. Super-admin power is contained by keeping it in
  # its own namespace, opting out of tenancy explicitly (rather than globally),
  # and auditing every action taken here.
  class BaseController < ApplicationController
    before_action :require_super_admin
    around_action :span_all_tenants

    private

    # 404, not 403: the existence of the platform console is not advertised to
    # tenant users.
    def require_super_admin
      render_not_found unless current_user&.super_admin?
    end

    def span_all_tenants(&block)
      ActsAsTenant.without_tenant(&block)
    end
  end
end
