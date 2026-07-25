require "rails_helper"

RSpec.describe "GET /api/pixel/leads/:id/activity" do
  let(:account) { create(:account) }
  let(:lead) { as_tenant(account) { create(:lead, account: account) } }
  let(:token) { Realtime::StreamToken.generate(lead) }

  def record(event_type, subject: lead, **payload)
    as_tenant(account) do
      Audit::Recorder.record!(event_type, subject: subject, payload: payload, actor: nil, account: account)
    end
  end

  def poll(id: lead.public_id, token: self.token, since: nil)
    get "/api/pixel/leads/#{id}/activity", params: { token: token, since: since }.compact
    response.parsed_body
  end

  def layer_completed(layer_key, panel_verdict: "pass", detail: "fine")
    record(Audit::Events::LAYER_COMPLETED,
           layer_key: layer_key, status: "completed", panel_verdict: panel_verdict, detail: detail)
  end

  describe "authorisation" do
    it "refuses a request carrying no token" do
      get "/api/pixel/leads/#{lead.public_id}/activity"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("stream_token_invalid")
    end

    it "refuses a tampered token" do
      poll(token: "#{token}tampered")

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses an expired token" do
      issued = token

      travel_to(Realtime::StreamToken::LIFETIME.from_now + 1.minute) { poll(token: issued) }

      expect(response).to have_http_status(:unauthorized)
    end

    # A token is a capability for one lead. Answering 404 for the mismatch would
    # confirm which ids exist, so both answers are the same 401.
    it "refuses a valid token issued for a different lead" do
      other_lead = as_tenant(account) { create(:lead, account: account) }

      poll(id: other_lead.public_id, token: token)

      expect(response).to have_http_status(:unauthorized)
    end

    it "answers a lead that does not exist exactly as it answers a bad token" do
      poll(id: "L-nonexistent")

      expect(response).to have_http_status(:unauthorized)
    end

    it "leaves an audit row for every refusal, as every other rejected call does" do
      expect { poll(token: "nonsense") }
        .to change { ActsAsTenant.without_tenant { AuditEvent.of_type(Audit::Events::API_REQUEST_REJECTED).count } }
        .by(1)
    end

    it "authorises without a pixel key or an allowed origin, since the token is the capability" do
      layer_completed("dnc")

      poll

      expect(response).to have_http_status(:ok)
    end

    # It carries no pixel key, so the per-key throttle cannot see it — but a poller
    # stuck in a tight loop is still abuse, and the per-source ceiling catches it.
    it "is throttled by source address like the rest of the pixel surface", :throttling do
      121.times { poll }

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "the activity it returns" do
    it "returns the same frames the socket sends, in order, with a cursor" do
      layer_completed("dnc", detail: "callable, window open")
      layer_completed("anura", panel_verdict: "warn", detail: "result: suspect")

      body = poll

      expect(body["events"].map { |frame| frame.except("id") }).to eq(
        [ { "type" => "layer_result", "layer" => "dnc", "verdict" => "pass",
            "detail" => "callable, window open" },
          { "type" => "layer_result", "layer" => "anura", "verdict" => "warn",
            "detail" => "result: suspect" } ]
      )
      expect(body["cursor"]).to eq(body["events"].last["id"])
    end

    # Otherwise a run whose most recent events are all unrenderable would be
    # re-read in full on every poll, forever.
    it "advances the cursor past events it did not render" do
      layer_completed("dnc")
      record(Audit::Events::LAYER_STARTED, layer_key: "anura")

      body = poll

      expect(body["events"].length).to eq(1)
      expect(body["cursor"]).to be > body["events"].last["id"]
    end

    it "returns only what is newer than the client's cursor" do
      layer_completed("dnc")
      first_cursor = poll["cursor"]
      layer_completed("anura")

      body = poll(since: first_cursor)

      expect(body["events"].map { |frame| frame["layer"] }).to eq([ "anura" ])
    end

    it "holds the cursor still when nothing new has happened" do
      layer_completed("dnc")
      cursor = poll["cursor"]

      body = poll(since: cursor)

      expect(body["events"]).to be_empty
      expect(body["cursor"]).to eq(cursor)
    end

    it "omits the events the panel does not render" do
      record(Audit::Events::LAYER_STARTED, layer_key: "dnc")
      layer_completed("dnc")

      expect(poll["events"].map { |frame| frame["type"] }).to eq([ "layer_result" ])
    end

    it "never returns another lead's activity" do
      other_lead = as_tenant(account) { create(:lead, account: account) }
      record(Audit::Events::LAYER_COMPLETED, subject: other_lead,
             layer_key: "anura", panel_verdict: "pass", detail: "theirs")
      layer_completed("dnc", detail: "ours")

      expect(poll["events"].map { |frame| frame["detail"] }).to eq([ "ours" ])
    end
  end

  describe "telling the poller when to stop" do
    it "is not done while the verification is still running" do
      layer_completed("dnc")

      expect(poll["done"]).to be(false)
    end

    it "is done once the verdict is in the client's hands" do
      layer_completed("dnc")
      record(Audit::Events::VERDICT_ISSUED, verdict: "accept", score: 90, reasons: [ "clean" ], flags: [])

      body = poll

      expect(body["events"].last).to include("type" => "final_verdict", "verdict" => "ACCEPT", "score" => 0.9)
      expect(body["done"]).to be(true)
    end

    it "stays done for a client polling past the verdict it already read" do
      record(Audit::Events::VERDICT_ISSUED, verdict: "accept", score: 90, reasons: [], flags: [])
      cursor = poll["cursor"]

      expect(poll(since: cursor)["done"]).to be(true)
    end

    # A client that has been away long enough to truncate its page must keep
    # polling rather than be told to stop before it has seen the verdict.
    it "is not done while the verdict is still beyond the page it was given" do
      stub_const("Api::Pixel::ActivitiesController::PAGE_LIMIT", 1)
      layer_completed("dnc")
      record(Audit::Events::VERDICT_ISSUED, verdict: "accept", score: 90, reasons: [], flags: [])

      body = poll

      expect(body["events"].length).to eq(1)
      expect(body["done"]).to be(false)
    end
  end
end
