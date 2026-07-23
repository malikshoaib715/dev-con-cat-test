require "rails_helper"

# The endpoint's behaviour is specced end to end in
# spec/requests/api/pixel/leads_spec.rb. What is left here is what a request spec
# cannot reach: two submissions of the same form arriving at once.
RSpec.describe Leads::IngestionService do
  def attributes(session_id: "sess_race")
    {
      session_id: session_id,
      page_url: "https://solar-savings.example.com/quote",
      submitted_at: Time.utc(2026, 7, 14, 15, 2, 11),
      ip_address: "76.14.201.33",
      fields: { first_name: "Maria", last_name: "Gonzalez", email: "maria.gonzalez@gmail.com", phone: "+13105550142" }
    }
  end

  describe "two submissions of the same form at the same instant", :real_transactions do
    # A double-clicked submit button, or a browser retrying a request it is not sure
    # landed. The in-Ruby replay check cannot settle this on its own, so the unique
    # index on (pixel_id, session_id) does: whoever loses the insert reports the
    # winner's lead instead of failing.
    it "creates one lead and charges the buyer once" do
      load_static_seeds
      load_provider_responses
      account = fixture_account("acct_solarpro")
      pixel = fixture_pixel_for(account)
      balance_before = account.credit_balance

      results = in_parallel(2, tenant: account) do
        described_class.call(pixel: ::Pixel.find(pixel.id), attributes: attributes)
      end

      expect(results).to all(be_success)
      expect(results.map { |result| result.value.lead.id }.uniq.size).to eq(1)
      expect(results.count { |result| result.value.replayed }).to eq(1)

      expect(as_tenant(account) { Lead.count }).to eq(1)
      expect(as_tenant(account) { VerificationRun.count }).to eq(1)
      expect(as_tenant(account) { account.credit_ledger_entries.entry_type_reservation.count }).to eq(1)
      expect(account.reload.credit_balance).to eq(balance_before - 17)
    end

    it "leaves exactly one set of layer rows behind" do
      load_static_seeds
      load_provider_responses
      account = fixture_account("acct_solarpro")
      pixel = fixture_pixel_for(account)

      in_parallel(2, tenant: account) do
        described_class.call(pixel: ::Pixel.find(pixel.id), attributes: attributes)
      end

      expect(as_tenant(account) { LayerResult.count }).to eq(10)
    end
  end
end
