# frozen_string_literal: true

class AuditEventPolicy < ApplicationPolicy
  def index? = account_member?
  def show?  = same_account?
end
