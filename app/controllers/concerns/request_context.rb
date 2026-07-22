# frozen_string_literal: true

# Stamps the per-request identity every audit event and log line is correlated
# by. Set once, at the boundary; nothing below the controller layer reads
# request state any other way.
module RequestContext
  extend ActiveSupport::Concern

  included do
    before_action :set_request_context
  end

  private

  def set_request_context
    Current.request_id = request.request_id
    Current.ip_address = request.remote_ip
  end
end
