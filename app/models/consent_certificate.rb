# frozen_string_literal: true

# The artifact a buyer would hand a regulator. Immutable by construction: no
# updated_at column, no update routes, and readonly once persisted. Each one
# names its predecessor's hash, so editing history breaks every later link.
class ConsentCertificate < ApplicationRecord
  include HasPublicId
  public_id_prefix "cert_"

  acts_as_tenant :account

  enum :verdict, ConsensusVerdict::VERDICTS.index_by(&:itself), prefix: true, validate: true

  belongs_to :lead
  belongs_to :verification_run

  validates :evidence_hash, presence: true
  validates :sequence_number,
            numericality: { only_integer: true, greater_than: 0 },
            uniqueness: { scope: :account_id }
  validates :issued_at, presence: true

  scope :recent_first, -> { order(sequence_number: :desc) }
  scope :chain_order,  -> { order(:sequence_number) }

  def readonly?
    persisted?
  end
end
