# frozen_string_literal: true

# The event spine. The live pixel panel, the lead activity timeline, and the
# audit explorer are three views over this one table, so it is append-only and
# every write goes through Audit::Recorder.
class AuditEvent < ApplicationRecord
  # Platform-level events (a failed login for an unknown email) belong to no tenant.
  acts_as_tenant :account, optional: true

  belongs_to :subject, polymorphic: true, optional: true

  validates :event_type, presence: true, inclusion: { in: ->(_) { Audit::Events::ALL } }
  validates :actor_type, presence: true
  validates :occurred_at, presence: true

  scope :chronological, -> { order(:occurred_at, :id) }
  scope :recent_first,  -> { order(occurred_at: :desc, id: :desc) }
  scope :of_type,       ->(event_type) { where(event_type: event_type) }
  scope :for_session,   ->(session_id) { where(session_id: session_id) }
  scope :for_subject,   ->(subject) { where(subject_type: subject.class.name, subject_id: subject.id) }
  scope :occurred_from, ->(time) { where(occurred_at: time..) }
  scope :occurred_to,   ->(time) { where(occurred_at: ..time) }

  def readonly?
    persisted?
  end
end
