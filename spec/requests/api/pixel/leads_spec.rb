require "rails_helper"

RSpec.describe "POST /api/pixel/leads" do
  let(:account) { fixture_account("acct_solarpro") }
  let(:pixel) { fixture_pixel_for(account) }
  let(:allowed_origin) { "https://solar-savings.example.com" }

  before do
    load_static_seeds
    load_provider_responses
  end

  def submit(body: {}, key: pixel.public_key, origin: allowed_origin)
    headers = { "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "76.14.201.33" }
    headers[PixelRequest::KEY_HEADER] = key if key
    headers["HTTP_ORIGIN"] = origin if origin

    post "/api/pixel/leads", params: valid_body.deep_merge(body).to_json, headers: headers
  end

  def valid_body
    {
      session_id: "sess_submit_1",
      pixel_id: pixel.public_id,
      submitted_at: "2026-07-14T15:02:11Z",
      form_dwell_ms: 48_210,
      page_url: "https://solar-savings.example.com/quote",
      fields: {
        first_name: "Maria",
        last_name: "Gonzalez",
        email: "Maria.Gonzalez@GMAIL.com",
        phone: "(310) 555-0142",
        consent: "on"
      }
    }
  end

  def leads
    as_tenant(account) { Lead.all }
  end

  # Scoped to this submission's session: seeding the fixture accounts writes its own
  # credit-grant events, which are not what these examples are about.
  def event_types
    ActsAsTenant.without_tenant { AuditEvent.for_session("sess_submit_1").chronological.pluck(:event_type) }
  end

  def envelope
    response.parsed_body["error"]
  end

  describe "the happy path" do
    before { submit }

    it "answers 201 with the key the pixel subscribes by" do
      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to include(
        "lead_id" => leads.sole.public_id,
        "channel" => "VerificationChannel",
        "replayed" => false
      )
      expect(response.parsed_body["stream_token"]).to be_present
    end

    it "issues a stream token that names this lead and nothing else" do
      token = response.parsed_body.fetch("stream_token")

      expect(Realtime::StreamToken.lead_public_id(token)).to eq(leads.sole.public_id)
    end

    it "records the lead against the account the key belongs to" do
      lead = leads.sole

      expect(lead.account_id).to eq(account.id)
      expect(lead.pixel_id).to eq(pixel.id)
      expect(lead.status).to eq("verifying")
      expect(lead.full_name).to eq("Maria Gonzalez")
      expect(lead.submitted_at).to eq(Time.utc(2026, 7, 14, 15, 2, 11))
      expect(lead.form_dwell_ms).to eq(48_210)
    end

    # Identity is stored twice: as the visitor typed it, and normalized for
    # matching. Duplicate detection and the fixture lookup both depend on the
    # second.
    it "keeps what the visitor typed and what it normalizes to" do
      lead = leads.sole

      expect(lead.email).to eq("Maria.Gonzalez@GMAIL.com")
      expect(lead.email_normalized).to eq("maria.gonzalez@gmail.com")
      expect(lead.phone).to eq("(310) 555-0142")
      expect(lead.phone_normalized).to eq("+13105550142")
    end

    it "takes the address from the connection, not the payload" do
      expect(leads.sole.ip_address).to eq("76.14.201.33")
    end

    it "keeps the submitted payload for later dispute" do
      expect(leads.sole.raw_payload).to include("first_name" => "Maria", "consent" => "on")
    end
  end

  # Pre-created rows are what make the three states first-class from t0 rather than
  # inferred later from a row's absence.
  describe "the layer rows it pre-creates" do
    before { submit }

    # Resolved inside the tenant: a relation returned from as_tenant would be
    # evaluated later, outside it.
    def layer_results
      as_tenant(account) { leads.sole.layer_results.to_a }
    end

    it "creates one row per layer in the registry, not one per purchased layer" do
      expect(layer_results.size).to eq(10)
      expect(layer_results.map(&:layer_key)).to match_array(Layers::Registry.keys)
    end

    # acct_solarpro buys nine of the ten modules; voice is the one it does not.
    it "marks the nine purchased layers pending and the unpurchased one not_enabled" do
      expect(layer_results.select { |row| row.status == "pending" }.map(&:layer_key))
        .to match_array(Layers::Registry.keys - %w[voice])

      voice = layer_results.find { |row| row.layer_key == "voice" }
      expect(voice.status).to eq("not_enabled")
      expect(voice.panel_verdict).to eq("skip")
      expect(voice.detail).to eq("not included in this account's plan")
      expect(voice.completed_at).to be_present
    end

    it "starts the run so the panel has something to render" do
      run = as_tenant(account) { leads.sole.verification_run }

      expect(run.status).to eq("running")
      expect(run.started_at).to be_present
      expect(run.reserved_credits).to eq(17)
    end
  end

  describe "the money" do
    it "reserves this account's own cost per run, up front" do
      expect { submit }.to change { account.reload.credit_balance }.by(-17)
    end

    it "writes a ledger entry naming what each layer cost" do
      submit

      entry = as_tenant(account) { account.credit_ledger_entries.entry_type_reservation.sole }
      expect(entry.amount).to eq(-17)
      expect(entry.breakdown.values.sum).to eq(17)
      expect(entry.verification_run_id).to eq(as_tenant(account) { leads.sole.verification_run.id })
    end
  end

  describe "the audit trail" do
    before { submit }

    # The order is the story: the lead arrived, then it was paid for, then work
    # began. Recording "verification started" before knowing it could be afforded
    # would be a lie.
    it "records arrival, payment and the start of work, in that order" do
      expect(event_types.first(3)).to eq(
        [ Audit::Events::LEAD_RECEIVED, Audit::Events::CREDITS_RESERVED, Audit::Events::VERIFICATION_STARTED ]
      )
    end

    it "attributes every event to the pixel and correlates it to the session" do
      events = ActsAsTenant.without_tenant { AuditEvent.for_session("sess_submit_1") }

      expect(events.count).to eq(3)
      expect(events.pluck(:actor_type).uniq).to eq([ "pixel" ])
      expect(events.pluck(:account_id).uniq).to eq([ account.id ])
    end
  end

  describe "dispatching the layers" do
    # Sidekiq's queue is not our database. A job enqueued inside the transaction
    # can be picked up before the rows it needs are committed.
    it "enqueues one job per purchased layer, and only after the commit" do
      expect { submit }.to change { enqueued_jobs.size }.by(9)

      expect(enqueued_jobs.map { |job| job[:args].last })
        .to match_array(Layers::Registry.keys - %w[voice])
    end

    it "enqueues nothing for a lead it could not accept" do
      as_tenant(account) { account.update!(credit_balance: 0) }

      expect { submit }.not_to change { enqueued_jobs.size }
    end

    # Redis being down must never cost a buyer a lead.
    describe "when the queue is unreachable" do
      before do
        allow(ActiveJob).to receive(:perform_all_later).and_raise(RedisClient::CannotConnectError, "no redis")
        submit
      end

      it "still accepts the lead" do
        expect(response).to have_http_status(:created)
        expect(leads.sole.status).to eq("verifying")
      end

      it "leaves the run recoverable rather than lost" do
        run = as_tenant(account) { leads.sole.verification_run }

        expect(run.status).to eq("pending")
        # Undispatched runs are exactly what the requeue task looks for once they
        # have sat still long enough to be certain nobody is working on them.
        travel 6.minutes do
          expect(as_tenant(account) { VerificationRun.stuck.to_a }).to include(run)
        end
      end

      it "records why it was never dispatched" do
        event = ActsAsTenant.without_tenant { AuditEvent.of_type(Audit::Events::SYSTEM_ENQUEUE_FAILED).sole }

        expect(event.payload).to include("error_class" => "RedisClient::CannotConnectError")
      end
    end
  end

  describe "an account that cannot afford the run" do
    before do
      as_tenant(account) { account.update!(credit_balance: 3) }
      submit
    end

    it "answers 402 with a message the page can show" do
      expect(response).to have_http_status(:payment_required)
      expect(envelope).to include("code" => "insufficient_credits")
      expect(envelope["message"]).to include("costs 17 and the balance is 3")
    end

    # The person filled the form in. Losing them because the buyer forgot to top up
    # would be the worst possible outcome.
    it "keeps the lead, held" do
      expect(leads.sole.status).to eq("on_hold_insufficient_credits")
    end

    it "creates no run, so nothing can later mistake it for work waiting to start" do
      expect(as_tenant(account) { VerificationRun.count }).to eq(0)
      expect(as_tenant(account) { LayerResult.count }).to eq(0)
    end

    it "charges nothing" do
      expect(account.reload.credit_balance).to eq(3)
      expect(as_tenant(account) { account.credit_ledger_entries.entry_type_reservation.count }).to eq(0)
    end

    it "records both the shortfall and the hold" do
      expect(event_types).to include(Audit::Events::CREDITS_INSUFFICIENT, Audit::Events::LEAD_ON_HOLD)
    end
  end

  describe "a resubmitted form" do
    before { submit }

    # A double-click, a retried request, a reloaded confirmation page. The buyer is
    # charged once.
    it "answers 200 with the lead that already exists" do
      original_lead_id = response.parsed_body.fetch("lead_id")

      submit

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("lead_id" => original_lead_id, "replayed" => true)
      expect(leads.count).to eq(1)
    end

    it "still hands back a usable stream token, so a reloaded page can resubscribe" do
      submit

      expect(Realtime::StreamToken.lead_public_id(response.parsed_body.fetch("stream_token")))
        .to eq(leads.sole.public_id)
    end

    it "charges nothing the second time" do
      expect { submit }.not_to change { account.reload.credit_balance }
    end

    it "dispatches nothing the second time" do
      expect { submit }.not_to change { enqueued_jobs.size }
    end

    it "records the replay, so a flood of them is visible rather than silent" do
      submit

      expect(event_types).to include(Audit::Events::LEAD_REPLAY_DETECTED)
    end

    it "treats the same session on a different pixel as a different lead" do
      other_pixel = as_tenant(account) do
        create(:pixel, account: account, allowed_domains: [ "solar-savings.example.com" ],
                       enabled_layers: pixel.enabled_layers)
      end

      submit(key: other_pixel.public_key)

      expect(response).to have_http_status(:created)
      expect(leads.count).to eq(2)
    end
  end

  describe "tenancy" do
    let(:other_account) { fixture_account("acct_medicareedge") }

    # The defense against posting leads into somebody else's account: the payload is
    # never consulted about which tenant it belongs to.
    it "ignores an account and pixel named in the payload" do
      other_pixel = fixture_pixel_for(other_account)

      submit(body: { pixel_id: other_pixel.public_id, account_id: other_account.public_id,
                     fields: { account_id: other_account.public_id } })

      expect(leads.sole.account_id).to eq(account.id)
      expect(as_tenant(other_account) { Lead.count }).to eq(0)
    end

    it "charges the key's account, not the one the payload names" do
      expect { submit(body: { account_id: other_account.public_id }) }
        .to change { account.reload.credit_balance }.by(-17)

      expect(other_account.reload.credit_balance).to eq(120_000)
    end
  end

  describe "a payload it cannot accept" do
    it "refuses a submission with no session to correlate to" do
      submit(body: { session_id: nil })

      expect(response).to have_http_status(:unprocessable_content)
      expect(envelope).to include("code" => "validation_failed")
      expect(leads.count).to eq(0)
    end

    # A lead nobody can be reached at is worth nothing to a buyer, so no run is ever
    # funded for one.
    it "refuses a submission with neither an email nor a phone number" do
      submit(body: { fields: { email: nil, phone: nil } })

      expect(response).to have_http_status(:unprocessable_content)
      expect(envelope["message"]).to include("email address or a phone number")
      expect(leads.count).to eq(0)
      expect(account.reload.credit_balance).to eq(25_000)
    end

    it "refuses a pixel configured to run no layers at all" do
      as_tenant(account) { pixel.update!(enabled_layers: []) }

      submit

      expect(response).to have_http_status(:unprocessable_content)
      expect(envelope["message"]).to include("no enabled layers")
      expect(leads.count).to eq(0)
    end
  end

  describe "authentication and origin" do
    it "refuses an unknown key before looking at the payload" do
      submit(key: "pk_not_a_real_key")

      expect(response).to have_http_status(:unauthorized)
      expect(leads.count).to eq(0)
    end

    it "refuses an origin the pixel's owner never allowed" do
      submit(origin: "https://scraped-the-snippet.example.com")

      expect(response).to have_http_status(:forbidden)
      expect(leads.count).to eq(0)
    end
  end
end
