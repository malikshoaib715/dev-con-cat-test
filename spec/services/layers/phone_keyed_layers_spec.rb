require "rails_helper"

# Three of the ten layers are phone lookups, and they share a precondition the
# vendor fixtures do not enforce for them: there has to be a number to look up.
#
# Ingestion accepts a lead with one identity, not both, so an email-only lead is
# legitimate — and a visitor can type anything into a phone field. Every fixture
# here answers about an identity rather than refusing an unusable one, so without
# this guard a lead whose "phone" is punctuation collects three clean passes, a
# score of 100, and a signed certificate attesting that three providers verified
# a valid mobile number. Those three claims are the ones a buyer would later be
# defending in court.
RSpec.describe "the layers that key on a phone number" do
  # What each vendor would have said, had it been asked. Deliberately the clean
  # answer in every case: the point is that a pass is available and refused.
  CLEAN_VENDOR_ANSWERS = {
    Layers::DncProcessor => { "dnc_status" => "clean", "callback_window_open" => true },
    Layers::BlacklistAllianceProcessor => { "status" => "clean", "match_score" => 0 },
    Layers::PhoneValidationProcessor => {
      "providers" => {
        "twilio_lookup" => { "valid" => true, "line_type" => "mobile" },
        "numverify"     => { "valid" => true, "line_type" => "mobile" },
        "telesign"      => { "valid" => true, "line_type" => "mobile" }
      }
    }
  }.freeze

  def lead_with_phone(raw)
    account = create(:account)
    as_tenant(account) do
      create(:lead, account: account, phone: raw, phone_normalized: Leads::Normalizer.phone(raw))
    end
  end

  def judge(processor, lead)
    allow(Providers::Gateway).to receive(:fetch)
      .with(layer_key: processor.layer_key, lead: lead)
      .and_return(CLEAN_VENDOR_ANSWERS.fetch(processor))

    as_tenant(lead.account) { processor.call(lead: lead) }
  end

  CLEAN_VENDOR_ANSWERS.each_key do |processor|
    describe processor.name do
      it "refuses to judge a phone field with no number in it" do
        outcome = judge(processor, lead_with_phone(",dc kwc qkcjn q"))

        expect(outcome.status).to eq("not_applicable")
        expect(outcome.verdict).to be_nil
        expect(outcome.panel_verdict).to eq("skip")
        expect(outcome.detail).to eq("no dialable phone number on the lead")
      end

      it "refuses to judge a fragment too short to dial" do
        expect(judge(processor, lead_with_phone("12345")).status).to eq("not_applicable")
      end

      it "judges a real number normally" do
        expect(judge(processor, lead_with_phone("+1 310 555 0142")).status).to eq("completed")
      end
    end
  end
end
