# frozen_string_literal: true

module ApplicationCable
  # Deliberately unidentified: there is no `identified_by`, because the visitor
  # on a buyer's landing page has no account with us and never signs in.
  #
  # The socket therefore grants nothing on its own — it is the per-subscription
  # stream token that names one lead and expires (see VerificationChannel). The
  # security boundary is the subscription, not the connection.
  class Connection < ActionCable::Connection::Base
  end
end
