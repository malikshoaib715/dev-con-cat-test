module TenancyHelpers
  # Tenant-owned models refuse to be read or written outside a tenant
  # (require_tenant is on), so specs open one explicitly. That is the point:
  # every fixture in a spec is visibly attributed to an account.
  def as_tenant(account, &block)
    ActsAsTenant.with_tenant(account, &block)
  end
end

RSpec.configure do |config|
  config.include TenancyHelpers

  config.after { ActsAsTenant.current_tenant = nil }
end
