# frozen_string_literal: true

class Lead < ApplicationRecord
  include HasPublicId
  public_id_prefix "L-"

  acts_as_tenant :account

  STATUSES = %w[received verifying on_hold_insufficient_credits completed].freeze
  VERDICTS = %w[accept review reject].freeze

  enum :status,  STATUSES.index_by(&:itself), validate: true
  enum :verdict, VERDICTS.index_by(&:itself), prefix: true, validate: { allow_nil: true }

  belongs_to :pixel

  has_one  :verification_run,    dependent: :destroy
  has_one  :consent_certificate, dependent: :restrict_with_error
  has_many :layer_results, through: :verification_run
  # Flattened so a list view can preload the score in one query rather than
  # walking run → verdict a row at a time.
  has_one  :consensus_verdict, through: :verification_run

  validates :session_id, presence: true, uniqueness: { scope: :pixel_id }
  validates :submitted_at, presence: true
  validate  :reachable_identity_present

  scope :recent_first,   -> { order(created_at: :desc) }
  scope :with_verdict,   ->(verdict) { where(verdict: verdict) }
  scope :with_status,    ->(status) { where(status: status) }
  scope :flagged_with,   ->(flag) { where("flags @> ?", [ flag ].to_json) }
  scope :submitted_from, ->(time) { where(submitted_at: time..) }
  scope :submitted_to,   ->(time) { where(submitted_at: ..time) }
  # The twelve fixture personas keep the ids they were seeded with (L-1001…),
  # while a lead captured at runtime is given a random one (HasPublicId). That
  # difference is what lets the demo cheat sheet list the seeded scenarios
  # without the demo's own submissions piling up underneath them.
  scope :seeded_personas, -> { where("public_id ~ '^L-[0-9]{4}$'") }

  # The CRM search box. A buyer types what they have — a number off a call sheet,
  # an address, half a name — so the term is normalized the same two ways every
  # identity in this system is (Leads::Normalizer) and matched exactly against the
  # indexed columns, with the name as the fallback. "(646) 555-0193" and
  # "+16465550193" are therefore the same search, which is the whole point of
  # storing the normalized forms.
  #
  # A term with no digits normalizes to no phone, and `= NULL` matches nothing, so
  # the irrelevant arms cost nothing rather than needing to be branched around.
  # Bound parameters throughout; the name arm is a scan by nature and is last.
  scope :search, ->(term) {
    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"

    where("leads.phone_normalized = :phone OR leads.email_normalized = :email OR " \
          "COALESCE(leads.first_name, '') || ' ' || COALESCE(leads.last_name, '') ILIKE :pattern",
          phone: Leads::Normalizer.phone(term), email: Leads::Normalizer.email(term), pattern: pattern)
  }

  def full_name
    [ first_name, last_name ].compact_blank.join(" ").presence
  end

  private

  # An unverifiable lead is worthless to a buyer: they need something to dial or
  # mail. Enforced at ingestion so no run is ever funded for an empty record.
  def reachable_identity_present
    return if email.present? || phone.present?

    errors.add(:base, "a lead needs at least an email address or a phone number")
  end
end
