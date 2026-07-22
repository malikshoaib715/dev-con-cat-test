# frozen_string_literal: true

# Request/job scoped context, stamped once at the boundary and consumed by the
# audit recorder and the logs. Nothing below the controller/job layer reads
# request state any other way.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :account, :pixel, :request_id, :session_id, :ip_address

  # Who caused the event: a signed-in human, an embedded pixel, or the platform.
  def actor
    user || pixel
  end
end
