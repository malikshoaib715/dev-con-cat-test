# frozen_string_literal: true

# The event spine. The live pixel panel, the lead activity timeline, and the
# audit explorer are three views over this one table, so it is append-only and
# every write goes through Audit::Recorder.
class AuditEvent < ApplicationRecord
  # Platform-level events (a failed login for an unknown email) belong to no tenant.
  acts_as_tenant :account, optional: true

  belongs_to :subject, polymorphic: true, optional: true

  # Who a write can be attributed to, and what it can be written about. Both are
  # closed sets, so the explorer's filters offer exactly what the spine contains
  # and a hand-edited value is refused rather than queried for.
  ACTOR_TYPES   = %w[user pixel system].freeze
  SUBJECT_TYPES = %w[Lead Pixel Visit Account].freeze

  validates :event_type, presence: true, inclusion: { in: ->(_) { Audit::Events::ALL } }
  validates :actor_type, presence: true
  validates :occurred_at, presence: true

  scope :chronological, -> { order(:occurred_at, :id) }
  scope :recent_first,  -> { order(occurred_at: :desc, id: :desc) }
  scope :of_type,       ->(event_type) { where(event_type: event_type) }
  scope :for_session,   ->(session_id) { where(session_id: session_id) }
  scope :for_subject,   ->(subject) { where(subject_type: subject.class.name, subject_id: subject.id) }
  # A lead's whole story, which starts before the lead exists: the events written
  # against the record itself, plus everything sharing the browser session that
  # produced it — the visit beacon, and the submission that was refused or
  # replayed. Both sides carry the account, so the (account_id, occurred_at)
  # composite indexes serve the query rather than being stepped around.
  scope :for_lead_timeline, ->(lead) {
    within_account = where(account_id: lead.account_id)

    within_account.where(subject_type: "Lead", subject_id: lead.id)
                  .or(within_account.where(session_id: lead.session_id))
  }
  scope :for_actor_type,  ->(actor_type) { where(actor_type: actor_type) }
  # The explorer's subject filter, which arrives as the two columns from a link
  # rather than as a loaded record.
  scope :about, ->(subject_type, subject_id) { where(subject_type: subject_type, subject_id: subject_id) }
  scope :occurred_from, ->(time) { where(occurred_at: time..) }
  scope :occurred_to,   ->(time) { where(occurred_at: ..time) }
  # The polling fallback's cursor. Ordered and sliced by id rather than by time,
  # because two events written in the same millisecond must still have a stable
  # order for a client resuming from one of them.
  scope :after_id,      ->(id) { where(id: (id.to_i + 1)..).order(:id) }
  scope :up_to_id,      ->(id) { where(id: ..id.to_i) }

  def readonly?
    persisted?
  end
end
