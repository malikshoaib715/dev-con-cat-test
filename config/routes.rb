require "sidekiq/web"

Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Sessions only: users are seeded or invited, never self-registered.
  devise_for :users, skip: %i[registrations passwords]

  # Platform operators have no tenant of their own, so they land on the
  # platform surface rather than an account dashboard.
  authenticated :user, ->(user) { user.super_admin? } do
    root to: redirect("/admin"), as: :platform_root
  end

  authenticated :user do
    root "app/leads#index", as: :authenticated_root
  end

  devise_scope :user do
    root to: "devise/sessions#new"
  end

  # The buyer funnel the pixel is embedded on, served by us so the whole loop —
  # snippet, ingestion, layers, live panel — can be watched in one place.
  get "demo", to: "demo#show"

  # Public by design: a consent certificate only anyone can check is worth
  # checking. The unguessable cert_… id is the capability.
  get "verify/:public_id", to: "verifications#show", as: :verify_certificate

  # The public, cross-origin pixel surface. Authenticated by pixel key, not by
  # session, and protected by CORS + rack-attack (config/initializers).
  namespace :api do
    namespace :pixel do
      post "visit", to: "visits#create"
      resources :leads, only: :create do
        # The panel's fallback when the socket cannot be kept open. Authorised by
        # the stream token, not the pixel key, so `:id` is the lead's public id.
        get :activity, on: :member, to: "activities#show"
      end
    end
  end

  namespace :app do
    # `:id` is the L-… public id, so a CRM URL reads the way the buyer's own
    # records do — and a row id guessed by hand finds nothing.
    resources :leads, only: %i[index show] do
      # After a top-up, or after a fan-out that never reached the queue.
      post :reverify, on: :member
    end
    # Looked up by public_id, never by row id: the px_… identifier is the one the
    # buyer sees in their own snippet.
    resources :pixels
    resources :certificates, only: %i[index show]
    resources :audit_events, only: :index
    # Singular: an account has one ledger, and nothing here is writable.
    resource :credits, only: :show, controller: "credits"
  end

  # The platform operator's surface. Admin::BaseController opts out of tenancy
  # explicitly, per action, rather than the app being unscoped by default.
  namespace :admin do
    root "dashboard#index"
    resources :accounts, only: %i[index show]
    resources :audit_events, only: :index
  end

  # Never unauthenticated: the job console exposes lead payloads in job
  # arguments. A routing constraint rather than an authenticate block, so a
  # visitor without the role gets a 404 and is not told the console exists.
  constraints ->(request) { request.env["warden"]&.user&.super_admin? } do
    mount Sidekiq::Web => "/admin/sidekiq"
  end
end
