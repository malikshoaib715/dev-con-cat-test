# frozen_string_literal: true

# The buyer's own existing customers. Duplicate detection matches against this
# within one account only — the same person in two buyers' CRMs is two
# legitimate leads, not a duplicate.
class CrmRecord < ApplicationRecord
  acts_as_tenant :account

  validates :external_ref, presence: true, uniqueness: { scope: :account_id }
  validates :source_created_at, presence: true

  scope :matching_phone, ->(phone) { where.not(phone_normalized: nil).where(phone_normalized: phone) }
  scope :matching_email, ->(email) { where.not(email_normalized: nil).where(email_normalized: email) }
  scope :recent_first,   -> { order(source_created_at: :desc) }

  def full_name
    [ first_name, last_name ].compact_blank.join(" ").presence
  end
end
