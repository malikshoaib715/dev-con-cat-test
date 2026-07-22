FactoryBot.define do
  factory :visit do
    account
    pixel { association :pixel, account: account }
    sequence(:session_id) { |n| "sess_visit_#{n}" }
    ip_address { "76.14.201.33" }
    user_agent { "Mozilla/5.0" }
    page_url { "https://buyer.example.com/quote" }
    started_at { Time.current }
  end

  factory :lead do
    account
    pixel { association :pixel, account: account }
    sequence(:session_id) { |n| "sess_lead_#{n}" }
    first_name { "Maria" }
    last_name  { "Gonzalez" }
    email { "maria.gonzalez@example.com" }
    email_normalized { email }
    phone { "+13105550142" }
    phone_normalized { phone }
    ip_address { "76.14.201.33" }
    page_url { "https://buyer.example.com/quote" }
    status { "received" }
    submitted_at { Time.current }
  end

  factory :verification_run do
    account
    lead { association :lead, account: account }
    status { "pending" }
    reserved_credits { 17 }
  end

  factory :layer_result do
    account
    verification_run { association :verification_run, account: account }
    layer_key { "anura" }
    status { "pending" }
  end

  factory :consensus_verdict do
    account
    verification_run { association :verification_run, account: account }
    verdict { "accept" }
    score { 100 }
    reasons { [ "all enabled layers passed" ] }
    issued_at { Time.current }
  end

  factory :consent_certificate do
    account
    verification_run { association :verification_run, account: account }
    lead { verification_run.lead }
    verdict { "accept" }
    evidence { { "verdict" => "accept" } }
    evidence_hash { Digest::SHA256.hexdigest("evidence") }
    sequence(:sequence_number) { |n| n }
    issued_at { Time.current }
  end

  factory :credit_ledger_entry do
    account
    entry_type { "grant" }
    amount { 100 }
    balance_after { 100 }
    created_at { Time.current }
  end

  factory :audit_event do
    account
    event_type { Audit::Events::LEAD_RECEIVED }
    actor_type { "system" }
    payload { {} }
    occurred_at { Time.current }
  end
end
