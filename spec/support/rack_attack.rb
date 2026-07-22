RSpec.configure do |config|
  # Throttling is off by default in test so counters cannot leak between
  # examples; the specs that exercise it turn it on for themselves.
  config.around(throttling: true) do |example|
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    example.run
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store.clear
  end
end
