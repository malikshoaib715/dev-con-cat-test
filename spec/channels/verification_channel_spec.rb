require "rails_helper"

RSpec.describe VerificationChannel do
  let(:account) { create(:account) }
  let(:lead) { as_tenant(account) { create(:lead, account: account) } }

  it "streams a lead's activity to a page holding that lead's token" do
    subscribe(stream_token: Realtime::StreamToken.generate(lead))

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("verification:#{lead.public_id}")
  end

  it "rejects a subscription that presents no token" do
    subscribe

    expect(subscription).to be_rejected
  end

  it "rejects a token that has been tampered with" do
    subscribe(stream_token: "#{Realtime::StreamToken.generate(lead)}tampered")

    expect(subscription).to be_rejected
  end

  # The capability is short-lived on purpose: a page only needs it for as long as
  # its own verification takes.
  it "rejects a token that has expired" do
    token = Realtime::StreamToken.generate(lead)

    travel_to(Realtime::StreamToken::LIFETIME.from_now + 1.minute) do
      subscribe(stream_token: token)
    end

    expect(subscription).to be_rejected
  end

  it "rejects a token signed for a different purpose" do
    other_purpose = Rails.application.message_verifier(:something_else).generate(lead.public_id)

    subscribe(stream_token: other_purpose)

    expect(subscription).to be_rejected
  end

  # The session id a page holds is generated client-side and is therefore
  # guessable; the token is what stops it being used to watch a stranger.
  it "never streams another lead's activity to a token issued for this one" do
    other_lead = as_tenant(account) { create(:lead, account: account) }

    subscribe(stream_token: Realtime::StreamToken.generate(lead))

    expect(subscription).not_to have_stream_from("verification:#{other_lead.public_id}")
  end
end
