module ConcurrencyHelpers
  # Runs the block on its own database connection with the tenant and request
  # context a real worker would have. Current and ActsAsTenant are both
  # thread-local, so a thread that does not set them up sees no tenant at all.
  def in_parallel(count, tenant:, &block)
    Array.new(count) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActsAsTenant.with_tenant(tenant) { block.call(index) }
        end
      end
    end.map(&:value)
  end
end

RSpec.configure do |config|
  config.include ConcurrencyHelpers

  # RSpec wraps every example in a transaction it rolls back. Two kinds of example
  # cannot live with that: threads cannot see each other's writes inside one
  # uncommitted transaction, and a service that asserts it was *given* a
  # transaction would always find RSpec's. These examples manage their own and
  # clean up by truncation afterwards.
  config.around(:each, :real_transactions) do |example|
    self.use_transactional_tests = false
    example.run
  ensure
    connection = ActiveRecord::Base.connection
    connection.truncate_tables(*(connection.tables - %w[schema_migrations ar_internal_metadata]))
  end
end
