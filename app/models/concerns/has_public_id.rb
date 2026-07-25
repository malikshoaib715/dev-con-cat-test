# frozen_string_literal: true

# Stripe-style external identifiers. Fixture ids like "acct_solarpro" cannot be
# bigint primary keys, and exposing sequential primary keys in URLs and pixel
# payloads leaks volume, so every publicly addressable record carries one.
module HasPublicId
  extend ActiveSupport::Concern

  RANDOM_SUFFIX_BYTES = 5

  included do
    validates :public_id, presence: true, uniqueness: true

    before_validation :assign_public_id, on: :create
  end

  class_methods do
    def public_id_prefix(prefix = nil)
      @public_id_prefix = prefix if prefix
      @public_id_prefix
    end
  end

  # URLs address these records by the identifier their owner reads off a snippet,
  # an invoice or a certificate — never by a sequential row id.
  def to_param
    public_id
  end

  private

  def assign_public_id
    self.public_id ||= "#{self.class.public_id_prefix}#{SecureRandom.hex(RANDOM_SUFFIX_BYTES)}"
  end
end
