# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.3.0"

gem "rails", "~> 8.1.3"
gem "pg", "~> 1.1"                # jsonb + GIN + partial indexes: the audit spine needs them
gem "puma", ">= 5.0"
gem "propshaft"                   # asset pipeline
gem "importmap-rails"             # ship Stimulus/Turbo without a bundler
gem "turbo-rails"                 # Turbo Streams give the CRM live updates off the same broadcast
gem "stimulus-rails"
gem "tailwindcss-rails"

gem "devise"                      # login-only auth surface (registerable off)
gem "pundit"                      # explicit role authorization, second layer after tenancy
gem "acts_as_tenant"              # query-layer account isolation
gem "sidekiq"                     # background layer jobs, per-stage queues
gem "redis", ">= 4.0.1"           # Sidekiq broker + Action Cable pub/sub
gem "rack-cors"                   # the pixel is cross-origin by definition
gem "rack-attack"                 # throttle the public pixel + login endpoints
gem "pagy"                        # pagination for the CRM and audit explorer

gem "bootsnap", require: false

group :development, :test do
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
  gem "foreman", require: false   # runs Procfile.dev (web, css, sidekiq)
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
end
