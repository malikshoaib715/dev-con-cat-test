# frozen_string_literal: true

class AuditEventPolicy < ApplicationPolicy
  # The platform explorer is the operator's read across every tenant, and is the
  # only place that breadth exists (Admin::BaseController opts out of tenancy
  # explicitly, and every read there is audited).
  def index? = account_member? || platform_operator?
  def show?  = same_account? || platform_operator?
end
