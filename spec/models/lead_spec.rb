require "rails_helper"

RSpec.describe Lead do
  let(:account) { create(:account) }
  let(:pixel)   { create(:pixel, account: account) }

  before { ActsAsTenant.current_tenant = account }

  it "assigns an L- prefixed external identifier" do
    lead = create(:lead, account: account, pixel: pixel)

    expect(lead.public_id).to start_with("L-")
  end

  it "requires something the buyer could actually contact" do
    lead = build(:lead, account: account, pixel: pixel, email: nil, phone: nil)

    expect(lead).not_to be_valid
    expect(lead.errors.full_messages.join).to include("email address or a phone number")
  end

  it "refuses a second lead for the same pixel session, so a replayed POST cannot double-charge" do
    create(:lead, account: account, pixel: pixel, session_id: "sess_dup")
    replay = build(:lead, account: account, pixel: pixel, session_id: "sess_dup")

    expect(replay).not_to be_valid
    expect { replay.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects a verdict outside the consensus vocabulary at the database level" do
    lead = create(:lead, account: account, pixel: pixel)

    expect { lead.update_column(:verdict, "maybe") }
      .to raise_error(ActiveRecord::StatementInvalid, /leads_verdict_valid/)
  end

  it "finds leads by a flag stored in the jsonb column" do
    flagged = create(:lead, account: account, pixel: pixel, flags: %w[soft_duplicate])
    create(:lead, account: account, pixel: pixel, flags: [])

    expect(Lead.flagged_with("soft_duplicate")).to contain_exactly(flagged)
  end
end
