# frozen_string_literal: true

module App
  class LeadsController < BaseController
    include Pagy::Backend

    def index
      leads = policy_scope(current_account.leads).recent_first.includes(:pixel)
      @pagy, @leads = pagy(leads)
    end
  end
end
