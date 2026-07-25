# frozen_string_literal: true

# The site-visit beacon. Its IP is what a later submission is compared against
# so the VPN layer can see "browsed residential, submitted through a VPN".
class Visit < ApplicationRecord
  acts_as_tenant :account

  belongs_to :pixel

  validates :session_id, presence: true, uniqueness: { scope: :pixel_id }
  validates :started_at, presence: true

  scope :recent_first, -> { order(started_at: :desc) }
  # The browsing that preceded a submission, matched on the correlation id the
  # page carries from beacon to form post. Its IP is what the lead's own is
  # compared against.
  scope :for_lead, ->(lead) { where(pixel_id: lead.pixel_id, session_id: lead.session_id) }
end
