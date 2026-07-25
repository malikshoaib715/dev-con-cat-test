# frozen_string_literal: true

# The live panel's transport. A page that has just submitted a lead presents the
# signed token it was handed with its 201 and receives that lead's activity as it
# happens.
#
# There is nothing else to authenticate: the visitor is anonymous. The token is
# the whole authorisation story — it names one lead, it was only ever given to
# the page that submitted it, and it expires (Realtime::StreamToken). A missing,
# tampered, expired, or foreign token all arrive here as nil and are rejected,
# so nobody can watch a stranger's verification by guessing a session id.
class VerificationChannel < ApplicationCable::Channel
  def subscribed
    lead_public_id = Realtime::StreamToken.lead_public_id(params[:stream_token])
    return reject if lead_public_id.blank?

    stream_from Realtime::PanelFrame.stream_name(lead_public_id)
  end
end
