# frozen_string_literal: true

class Pixel < ApplicationRecord
  include HasPublicId
  public_id_prefix "px_"

  acts_as_tenant :account

  has_many :visits, dependent: :destroy
  has_many :leads,  dependent: :restrict_with_error

  validates :name, presence: true
  validates :public_key, presence: true, uniqueness: true
  validate  :enabled_layers_are_known

  before_validation :assign_public_key, on: :create

  scope :active,  -> { where(active: true) }
  scope :ordered, -> { order(:created_at) }

  # A pixel can only ever run layers its account pays for. The intersection is
  # computed here, in registry order, so no caller can widen it.
  def effective_layer_keys
    paid_for = account.layer_policies.enabled.pluck(:layer_key)
    Layers::Registry.keys & paid_for & enabled_layers
  end

  def allows_origin?(origin)
    return false if origin.blank?

    host = URI.parse(origin).host
    allowed_domains.any? { |domain| domain.casecmp?(host.to_s) }
  rescue URI::InvalidURIError
    false
  end

  private

  def assign_public_key
    self.public_key ||= "pk_#{SecureRandom.hex(16)}"
  end

  def enabled_layers_are_known
    unknown = enabled_layers - Layers::Registry.keys
    return if unknown.empty?

    errors.add(:enabled_layers, "contains unknown layers: #{unknown.join(', ')}")
  end
end
