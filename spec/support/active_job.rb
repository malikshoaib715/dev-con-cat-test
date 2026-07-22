RSpec.configure do |config|
  config.include ActiveJob::TestHelper

  # Jobs are enqueued, never auto-run: specs that care about the pipeline call
  # perform_enqueued_jobs or perform_now explicitly, so ordering stays visible.
  config.before { ActiveJob::Base.queue_adapter = :test }
end
