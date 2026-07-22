require "capybara/rspec"

RSpec.configure do |config|
  config.before(type: :system) do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ]
  end

  # System specs drive a real browser against a real server thread, so the
  # request-side connection must see committed data.
  config.before(type: :system) { self.use_transactional_tests = false }
end
