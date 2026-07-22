RSpec.configure do |config|
  # Rails' executor resets Current per request; specs get the same guarantee so
  # a stray actor cannot leak from one example into the next.
  config.before { Current.reset }
end
