require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "action_cable/engine"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module SuperPixel
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    # Every timestamp in this system is a compliance artifact; store and reason in UTC.
    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc

    # Layer work is fanned out across Sidekiq queues (see config/sidekiq.yml).
    config.active_job.queue_adapter = :sidekiq

    config.generators do |generate|
      generate.system_tests = nil
      generate.helper false
      generate.assets false
    end
  end
end
