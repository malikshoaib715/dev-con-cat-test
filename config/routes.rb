require "sidekiq/web"

Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Sessions only: users are seeded or invited, never self-registered.
  devise_for :users, skip: %i[registrations passwords]

  # Platform operators have no tenant of their own, so they land on the
  # platform surface rather than an account dashboard.
  authenticated :user, ->(user) { user.super_admin? } do
    root to: redirect("/admin/sidekiq"), as: :platform_root
  end

  authenticated :user do
    root "app/leads#index", as: :authenticated_root
  end

  devise_scope :user do
    root to: "devise/sessions#new"
  end

  # The public, cross-origin pixel surface. Authenticated by pixel key, not by
  # session, and protected by CORS + rack-attack (config/initializers).
  namespace :api do
    namespace :pixel do
      post "visit", to: "visits#create"
      resources :leads, only: :create
    end
  end

  namespace :app do
    resources :leads, only: %i[index]
  end

  # Never unauthenticated: the job console exposes lead payloads in job
  # arguments. A routing constraint rather than an authenticate block, so a
  # visitor without the role gets a 404 and is not told the console exists.
  constraints ->(request) { request.env["warden"]&.user&.super_admin? } do
    mount Sidekiq::Web => "/admin/sidekiq"
  end
end
