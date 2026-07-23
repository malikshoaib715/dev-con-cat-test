RSpec.configure do |config|
  # Timestamps are compliance artifacts here (capture time, callback windows, the
  # duplicate-detection window), so specs need to be able to pin the clock.
  config.include ActiveSupport::Testing::TimeHelpers
end
