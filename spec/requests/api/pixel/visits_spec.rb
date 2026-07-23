require "rails_helper"

RSpec.describe "POST /api/pixel/visit" do
  let(:account) { create(:account) }
  let(:pixel) { as_tenant(account) { create(:pixel, account: account, allowed_domains: [ "solar-savings.example.com" ]) } }
  let(:allowed_origin) { "https://solar-savings.example.com" }

  def beacon(body: {}, key: pixel.public_key, origin: allowed_origin)
    headers = { "CONTENT_TYPE" => "application/json" }
    headers[PixelRequest::KEY_HEADER] = key if key
    headers["HTTP_ORIGIN"] = origin if origin

    post "/api/pixel/visit", params: valid_body.merge(body).to_json, headers: headers
  end

  def valid_body
    {
      session_id: "sess_abc123",
      pixel_id: pixel.public_id,
      page_url: "https://solar-savings.example.com/quote",
      referrer: "https://www.google.com/",
      started_at: "2026-07-14T15:00:00Z"
    }
  end

  def envelope
    response.parsed_body["error"]
  end

  def visits
    as_tenant(account) { Visit.all }
  end

  def audit_events
    ActsAsTenant.without_tenant { AuditEvent.of_type(Audit::Events::PIXEL_VISIT_RECORDED) }
  end

  describe "authentication" do
    it "refuses a call with no key at all" do
      beacon(key: nil)

      expect(response).to have_http_status(:unauthorized)
      expect(envelope).to include("code" => "pixel_not_authorized")
      expect(envelope["request_id"]).to be_present
    end

    it "refuses a key that belongs to no pixel" do
      beacon(key: "pk_not_a_real_key")

      expect(response).to have_http_status(:unauthorized)
      expect(envelope).to include("code" => "pixel_not_authorized")
    end

    # Deactivating a pixel has to actually stop it: the snippet is already out
    # there on the buyer's page and cannot be recalled.
    it "refuses the key of a deactivated pixel" do
      as_tenant(account) { pixel.update!(active: false) }

      beacon

      expect(response).to have_http_status(:unauthorized)
      expect(visits.count).to eq(0)
    end

    it "never says whether the key was unknown or merely inactive" do
      as_tenant(account) { pixel.update!(active: false) }
      beacon
      inactive_body = response.parsed_body["error"].except("request_id")

      beacon(key: "pk_not_a_real_key")

      expect(response.parsed_body["error"].except("request_id")).to eq(inactive_body)
    end
  end

  describe "origin enforcement" do
    it "refuses an origin the pixel's owner never allowed" do
      beacon(origin: "https://scraped-the-snippet.example.com")

      expect(response).to have_http_status(:forbidden)
      expect(envelope).to include("code" => "origin_not_allowed")
      expect(visits.count).to eq(0)
    end

    it "refuses a call that declares no origin at all" do
      beacon(origin: nil)

      expect(response).to have_http_status(:forbidden)
      expect(envelope).to include("code" => "origin_not_allowed")
    end

    it "accepts an allowed host on any port, since the demo runs on one" do
      as_tenant(account) { pixel.update!(allowed_domains: [ "localhost" ]) }

      beacon(origin: "http://localhost:3000")

      expect(response).to have_http_status(:accepted)
    end

    # Browsers omit Origin on some navigations but still send a referrer.
    it "falls back to the referrer when no origin header was sent" do
      post "/api/pixel/visit",
           params: valid_body.to_json,
           headers: {
             "CONTENT_TYPE" => "application/json",
             PixelRequest::KEY_HEADER => pixel.public_key,
             "HTTP_REFERER" => "https://solar-savings.example.com/quote"
           }

      expect(response).to have_http_status(:accepted)
    end
  end

  describe "recording the visit" do
    it "accepts the beacon and echoes the session it correlates to" do
      beacon

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to eq("session_id" => "sess_abc123")
    end

    it "attributes the visit to the account the key belongs to" do
      beacon

      visit = visits.sole
      expect(visit.account_id).to eq(account.id)
      expect(visit.pixel_id).to eq(pixel.id)
      expect(visit.page_url).to eq("https://solar-savings.example.com/quote")
      expect(visit.referrer).to eq("https://www.google.com/")
      expect(visit.started_at).to eq(Time.utc(2026, 7, 14, 15, 0, 0))
    end

    # The whole point of the beacon: this address is what the submit address is
    # later compared against, so it can never come from the body.
    it "takes the address from the connection, not from the payload" do
      post "/api/pixel/visit",
           params: valid_body.merge(ip_address: "8.8.8.8").to_json,
           headers: {
             "CONTENT_TYPE" => "application/json",
             PixelRequest::KEY_HEADER => pixel.public_key,
             "HTTP_ORIGIN" => allowed_origin,
             "REMOTE_ADDR" => "76.14.201.33",
             "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X)"
           }

      visit = visits.sole
      expect(visit.ip_address).to eq("76.14.201.33")
      expect(visit.user_agent).to eq("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X)")
    end

    it "starts the clock on arrival when the page did not say when it loaded" do
      freeze_time do
        beacon(body: { started_at: nil })

        expect(visits.sole.started_at).to eq(Time.current)
      end
    end

    it "keeps the interaction summary the page sends, and nothing else from it" do
      beacon(body: { interactions: [ { name: "email", action: "focus", at: "2026-07-14T15:00:04Z", secret: "dropped" } ] })

      expect(visits.sole.interactions).to eq(
        [ { "name" => "email", "action" => "focus", "at" => "2026-07-14T15:00:04Z" } ]
      )
    end

    # §6 keeps focus/blur churn off the audit spine by only ever persisting a
    # summary. The same protection is needed one level down: a looping or hostile
    # page must not be able to write an unbounded document into a single row.
    # Truncated rather than refused, because a beacon that fails is a beacon that
    # breaks somebody's landing page.
    it "caps a flood of interactions instead of storing whatever it is sent" do
      flood = Array.new(5_000) { |index| { name: "field#{index}", action: "focus", at: index.to_s } }

      beacon(body: { interactions: flood })

      expect(response).to have_http_status(:accepted)
      expect(visits.sole.interactions.size).to eq(Visits::Recorder::MAX_INTERACTIONS)
    end

    it "records the beacon on the audit spine, attributed to the pixel" do
      beacon

      event = audit_events.sole
      expect(event.actor_type).to eq("pixel")
      expect(event.actor_id).to eq(pixel.id)
      expect(event.account_id).to eq(account.id)
      expect(event.session_id).to eq("sess_abc123")
      expect(event.subject_type).to eq("Visit")
      expect(event.subject_id).to eq(visits.sole.id)
      expect(event.payload).to include("page_url" => "https://solar-savings.example.com/quote")
    end

    it "refuses a beacon with no session to correlate to" do
      beacon(body: { session_id: nil })

      expect(response).to have_http_status(:unprocessable_content)
      expect(envelope).to include("code" => "validation_failed")
      expect(visits.count).to eq(0)
    end
  end

  describe "idempotency" do
    # The beacon is sent with keepalive from a page that may be unloading, so a
    # retry is normal traffic and must never be an error.
    it "answers a re-fired beacon the same way and keeps one visit" do
      beacon
      beacon

      expect(response).to have_http_status(:accepted)
      expect(visits.count).to eq(1)
    end

    it "does not put a retried beacon on the timeline twice" do
      beacon
      beacon

      expect(audit_events.count).to eq(1)
    end

    it "treats the same session on a different pixel as a different visit" do
      other_pixel = as_tenant(account) do
        create(:pixel, account: account, allowed_domains: [ "solar-savings.example.com" ])
      end

      beacon
      beacon(key: other_pixel.public_key)

      expect(response).to have_http_status(:accepted)
      expect(visits.count).to eq(2)
    end
  end

  describe "tenancy" do
    let(:other_account) { create(:account) }

    # The key is the only thing that decides the account. A payload naming
    # somebody else's account or pixel changes nothing.
    it "ignores an account and pixel named in the payload" do
      other_pixel = as_tenant(other_account) do
        create(:pixel, account: other_account, allowed_domains: [ "solar-savings.example.com" ])
      end

      beacon(body: { account_id: other_account.id, pixel_id: other_pixel.public_id })

      expect(visits.sole.account_id).to eq(account.id)
      expect(as_tenant(other_account) { Visit.count }).to eq(0)
    end
  end
end
