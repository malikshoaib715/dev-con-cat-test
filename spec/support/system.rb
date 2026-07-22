require "capybara/rspec"

RSpec.configure do |config|
  config.before(type: :system) do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ]
  end
end

# Transactional tests are deliberately left on for system specs. Since Rails 5.1
# the test thread and the Capybara app server share one connection, so the
# rollback still cleans up and no truncation strategy is needed.
