# frozen_string_literal: true

ActsAsTenant.configure do |config|
  # Unscoped-by-default is how tenant leaks ship. Every query against a
  # tenant-owned model must happen inside a tenant, and the places that
  # legitimately span accounts (super-admin screens, the vendor fixture store,
  # platform-level audit events) opt out explicitly with `without_tenant`.
  config.require_tenant = true
end
