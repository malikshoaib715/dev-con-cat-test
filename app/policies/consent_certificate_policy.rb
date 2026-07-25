# frozen_string_literal: true

class ConsentCertificatePolicy < ApplicationPolicy
  def index? = account_member?
  def show?  = same_account?
end
