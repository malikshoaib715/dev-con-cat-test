# frozen_string_literal: true

# Default deny. Every permission a role has is written down somewhere below this
# class; nothing is granted by omission.
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?   = false
  def show?    = false
  def create?  = false
  def new?     = create?
  def update?  = false
  def edit?    = update?
  def destroy? = false

  private

  def signed_in?
    user.present?
  end

  def account_member?
    signed_in? && user.account_id.present?
  end

  def account_admin?
    signed_in? && (user.account_admin? || user.super_admin?)
  end

  # The second belt: acts_as_tenant already scopes the query, and this refuses
  # again on the record itself.
  def same_account?
    account_member? && record.respond_to?(:account_id) && record.account_id == user.account_id
  end

  class Scope
    attr_reader :user, :scope

    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      return scope.none if user.nil?
      # Only reachable inside an explicit ActsAsTenant.without_tenant block.
      return scope.all if user.super_admin?

      scope.where(account_id: user.account_id)
    end
  end
end
