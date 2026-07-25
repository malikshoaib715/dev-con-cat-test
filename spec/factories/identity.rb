FactoryBot.define do
  factory :account do
    sequence(:public_id) { |n| "acct_test#{n}" }
    sequence(:name)      { |n| "Test Buyer #{n}" }
    plan { "growth" }
    status { "active" }
    monthly_credit_allowance { 1_000 }
    credit_balance { 1_000 }
    cycle_start { Date.new(2026, 7, 1) }
    cycle_end   { Date.new(2026, 7, 31) }
    billing_email { "billing@example.com" }
  end

  factory :user do
    account
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:name)  { |n| "Test User #{n}" }
    password { "Sup3rPixel!pw" }
    role { "member" }

    trait :account_admin do
      role { "account_admin" }
    end

    trait :super_admin do
      role { "super_admin" }
      account { nil }
    end
  end

  factory :pixel do
    account
    sequence(:name) { |n| "Landing page #{n}" }
    allowed_domains { [ "buyer.example.com", "localhost" ] }
    enabled_layers { Layers::Registry.keys }
    active { true }
  end

  factory :layer_definition do
    key { Layers::Registry.keys.first }
    name { Layers::Registry.label(key) }
    position { Layers::Registry.fetch(key).position }
    cost_credits { 1 }
    criticality { "optional" }
    hard_stop_capable { false }
    default_weights { {} }
  end

  factory :layer_policy do
    account
    layer_key { Layers::Registry.keys.first }
    enabled { true }
  end

  factory :crm_record do
    account
    sequence(:external_ref) { |n| "CRM-#{n}" }
    first_name { "Existing" }
    last_name  { "Customer" }
    email { "existing@example.com" }
    email_normalized { "existing@example.com" }
    phone { "+13105550111" }
    phone_normalized { "+13105550111" }
    source_created_at { 1.month.ago }
  end

  factory :provider_response do
    layer_key { "anura" }
    sequence(:lead_ref) { |n| "L-90#{n}" }
    payload { { "result" => "good" } }
  end
end
