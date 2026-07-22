# frozen_string_literal: true

class PixelPolicy < ApplicationPolicy
  def index?   = account_member?
  def show?    = same_account?
  def create?  = account_admin? && account_member?
  def update?  = same_account? && account_admin?
  def destroy? = update?
end
