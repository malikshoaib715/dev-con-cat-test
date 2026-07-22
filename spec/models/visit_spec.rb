require "rails_helper"

RSpec.describe Visit do
  let(:account) { create(:account) }
  let(:pixel)   { create(:pixel, account: account) }

  before { ActsAsTenant.current_tenant = account }

  it "requires the capture session and the moment the page was opened" do
    visit = build(:visit, account: account, pixel: pixel, session_id: nil, started_at: nil)

    expect(visit).not_to be_valid
    expect(visit.errors[:session_id]).to be_present
    expect(visit.errors[:started_at]).to be_present
  end

  it "keeps one row per capture session, so a re-fired beacon updates rather than duplicating" do
    create(:visit, account: account, pixel: pixel, session_id: "sess_repeat")
    second_beacon = build(:visit, account: account, pixel: pixel, session_id: "sess_repeat")

    expect(second_beacon).not_to be_valid
    expect { second_beacon.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "lets two pixels use the same client-generated session id" do
    other_pixel = create(:pixel, account: account)
    create(:visit, account: account, pixel: pixel, session_id: "sess_shared")

    expect(build(:visit, account: account, pixel: other_pixel, session_id: "sess_shared")).to be_valid
  end

  it "records the visit IP that a later submission will be compared against" do
    visit = create(:visit, account: account, pixel: pixel, ip_address: "76.14.201.33")

    expect(visit.ip_address).to eq("76.14.201.33")
  end

  it "orders the most recent visit first" do
    older = create(:visit, account: account, pixel: pixel, started_at: 2.hours.ago)
    newer = create(:visit, account: account, pixel: pixel, started_at: 1.minute.ago)

    expect(described_class.recent_first.to_a).to eq([ newer, older ])
  end
end
