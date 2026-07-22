# frozen_string_literal: true

# The site-visit beacon. Its IP is what a later submission is compared against
# so the VPN layer can see "browsed residential, submitted through a VPN".
class Visit < ApplicationRecord
  acts_as_tenant :account

  belongs_to :pixel

  validates :session_id, presence: true, uniqueness: { scope: :pixel_id }
  validates :started_at, presence: true

  scope :recent_first, -> { order(started_at: :desc) }
end
