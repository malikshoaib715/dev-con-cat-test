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

    # Whichever of the two guards catches the loser depends purely on how the two
    # requests interleave, and both have to end in the same idempotent answer.
    # Blinding the pre-check reproduces the interleaving where the winner commits
    # between the loser's check and its INSERT: there the model's uniqueness
    # validation raises RecordInvalid, not the index's RecordNotUnique, and
    # rescuing only the latter answered a replay with 422.
    it "replays rather than failing when the winner commits mid-flight" do
      load_static_seeds
      load_provider_responses
      account = fixture_account("acct_solarpro")
      pixel = fixture_pixel_for(account)

      as_tenant(account) do
        described_class.call(pixel: ::Pixel.find(pixel.id), attributes: attributes)

        # False for the pre-check, true once the insert has failed: that is what a
        # fresh query returns on each side of the winner's commit.
        loser = described_class.new(pixel: ::Pixel.find(pixel.id), attributes: attributes)
        allow(loser).to receive(:already_submitted).and_return(false, true)
        result = loser.call

        expect(result).to be_success
        expect(result.value.replayed).to be(true)
        expect(Lead.count).to eq(1)
      end
    end

    # A lead that is invalid for its own reasons must still fail. The replay rescue
    # is narrowed to the session uniqueness so it cannot swallow a real one.
    it "still refuses a lead that is invalid on its merits" do
      load_static_seeds
      account = fixture_account("acct_solarpro")
      pixel = fixture_pixel_for(account)
      unreachable = attributes(session_id: "sess_unreachable").merge(fields: { first_name: "Nobody" })

      as_tenant(account) do
        expect { described_class.call(pixel: ::Pixel.find(pixel.id), attributes: unreachable) }
          .to raise_error(ActiveRecord::RecordInvalid, /email address or a phone number/)
      end
    end
  end

  # Every row written below the account references it, and each of those inserts
  # takes a key-share lock on the account row. Reserving credits then wants FOR
  # UPDATE on that same row, so with the lock taken last two submissions for one
  # account each waited on the other's key-share lock: Postgres broke the tie by
  # killing one, which surfaced as a 500 and lost that lead. Two different people
  # filling in one buyer's form at the same moment is ordinary traffic, not an
  # edge case, so it is specced as such.
  describe "two different visitors submitting to one account at once", :real_transactions do
    it "accepts both instead of deadlocking" do
      load_static_seeds
      load_provider_responses
      account = fixture_account("acct_solarpro")
      pixel = fixture_pixel_for(account)
      balance_before = account.credit_balance

      results = in_parallel(2, tenant: account) do |index|
        described_class.call(pixel: ::Pixel.find(pixel.id),
                             attributes: attributes(session_id: "sess_visitor_#{index}"))
      end

      expect(results).to all(be_success)
      expect(results.map { |result| result.value.lead.id }.uniq.size).to eq(2)
      expect(as_tenant(account) { Lead.count }).to eq(2)
      expect(account.reload.credit_balance).to eq(balance_before - 34)
    end

    it "keeps the ledger consistent with the balance under contention" do
      load_static_seeds
      load_provider_responses
      account = fixture_account("acct_solarpro")
      pixel = fixture_pixel_for(account)
      granted = as_tenant(account) { account.credit_ledger_entries.sum(:amount) }

      in_parallel(4, tenant: account) do |index|
        described_class.call(pixel: ::Pixel.find(pixel.id),
                             attributes: attributes(session_id: "sess_contended_#{index}"))
      end

      expect(as_tenant(account) { account.credit_ledger_entries.sum(:amount) }).to eq(granted - 68)
      expect(account.reload.credit_balance).to eq(as_tenant(account) { account.credit_ledger_entries.sum(:amount) })
    end
  end
end
