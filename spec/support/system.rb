require "capybara/rspec"

# The seeded pixels allow `localhost` precisely so the demo works out of the box
# (Seeds::Pixels::DEMO_DOMAIN). Capybara serves on 127.0.0.1 by default, which is
# a different host as far as the origin allowlist is concerned — and loosening the
# check to make a test pass would be the wrong repair.
Capybara.server_host = "localhost"

RSpec.configure do |config|
  config.before(type: :system) do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ]
  end
end

# Transactional tests are deliberately left on for system specs. Since Rails 5.1
# the test thread and the Capybara app server share one connection, so the
# rollback still cleans up and no truncation strategy is needed.
