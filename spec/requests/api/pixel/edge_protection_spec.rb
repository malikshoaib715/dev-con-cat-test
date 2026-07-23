require "rails_helper"

# The two pieces of protection that sit in front of every pixel endpoint, proven
# at the middleware layer: they answer before routing, so they are asserted here
# independently of any one controller.
RSpec.describe "Pixel edge protection" do
  let(:endpoint) { "/api/pixel/leads" }
  let(:buyer_origin) { "https://solar-savings.example.com" }

  describe "CORS" do
    it "answers a preflight from a buyer's own domain so a real embed can post" do
      process :options, endpoint, headers: {
        "HTTP_ORIGIN" => buyer_origin,
        "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST",
        "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => PixelRequest::KEY_HEADER
      }

      expect(response).to have_http_status(:ok)
      # Any origin is allowed through the browser's check; which origins may
      # actually submit is the pixel's allowed_domains decision, not CORS'.
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(response.headers["Access-Control-Allow-Methods"]).to include("POST")
    end

    it "advertises the key header so the browser lets the pixel send it" do
      process :options, endpoint, headers: {
        "HTTP_ORIGIN" => buyer_origin,
        "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST",
        "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => PixelRequest::KEY_HEADER
      }

      expect(response.headers["Access-Control-Allow-Headers"]).to include(PixelRequest::KEY_HEADER)
    end

    # Credentials are deliberately off: the pixel authenticates with a key, not a
    # cookie, so there is no session for another origin to ride.
    it "never grants credentialed access to the wildcard origin" do
      process :options, endpoint, headers: {
        "HTTP_ORIGIN" => buyer_origin,
        "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST"
      }

      expect(response.headers["Access-Control-Allow-Credentials"]).to be_nil
    end

    it "leaves the authenticated dashboard alone: it is same-origin only" do
      process :options, "/app/leads", headers: {
        "HTTP_ORIGIN" => buyer_origin,
        "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "GET"
      }

      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
    end
  end

  describe "throttling", :throttling do
    let(:key_throttle) { Rack::Attack.throttles.fetch("pixel/key") }
    let(:ip_throttle)  { Rack::Attack.throttles.fetch("pixel/ip") }

    def rack_request(path, headers = {})
      Rack::Attack::Request.new(Rack::MockRequest.env_for(path, headers))
    end

    # The end-to-end proof that the middleware is wired in front of the pixel
    # surface: a real flood through the whole stack, answered in the same
    # envelope as every other pixel failure and recorded for later querying.
    it "cuts off a key that floods the surface, and says so in the usual envelope" do
      # Rack::Attack counts into a bucket per period, so a flood that straddles a
      # bucket boundary is legitimately split across two of them. Pinning the
      # clock keeps the assertion about the limit rather than about the wall time
      # the example happened to start at.
      freeze_time do
        (key_throttle.limit + 1).times do
          post endpoint, headers: { PixelRequest::KEY_HEADER => "pk_flooding", "REMOTE_ADDR" => "203.0.113.9" }
        end
      end

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["error"]).to include("code" => "throttled")
      expect(response.parsed_body.dig("error", "request_id")).to be_present
      expect(response.headers["Retry-After"]).to eq("60")

      events = ActsAsTenant.without_tenant { AuditEvent.of_type(Audit::Events::API_THROTTLED) }
      expect(events.count).to eq(1)
      expect(events.first.payload).to include("rule" => "pixel/key", "path" => endpoint)
    end

    # The remaining rules are asserted on their discriminators rather than by
    # driving another few hundred requests through the stack: what needs proving
    # is which bucket a call is counted in, and the wiring is already shown above.
    it "counts each key in its own bucket, so one busy buyer cannot throttle another" do
      first  = rack_request(endpoint, PixelRequest::RACK_KEY_HEADER => "pk_one")
      second = rack_request(endpoint, PixelRequest::RACK_KEY_HEADER => "pk_two")

      expect(key_throttle.block.call(first)).to eq("pk_one")
      expect(key_throttle.block.call(second)).to eq("pk_two")
    end

    # Rotating keys is the obvious way around a per-key limit, so the source
    # address is counted independently of the key it presents.
    it "counts one source rotating through many keys as a single source" do
      first  = rack_request(endpoint, PixelRequest::RACK_KEY_HEADER => "pk_one",
                                      "REMOTE_ADDR" => "203.0.113.9")
      second = rack_request(endpoint, PixelRequest::RACK_KEY_HEADER => "pk_two",
                                      "REMOTE_ADDR" => "203.0.113.9")

      expect(ip_throttle.block.call(first)).to eq("203.0.113.9")
      expect(ip_throttle.block.call(second)).to eq("203.0.113.9")
    end

    it "gives a landing page far more headroom than a sign-in form" do
      expect(key_throttle.limit).to eq(60)
      expect(ip_throttle.limit).to eq(120)
      expect([ key_throttle.period, ip_throttle.period ]).to all(eq(60))
    end

    it "leaves the authenticated dashboard out of the pixel throttles" do
      dashboard = rack_request("/app/leads", PixelRequest::RACK_KEY_HEADER => "pk_one",
                                             "REMOTE_ADDR" => "203.0.113.9")

      expect(key_throttle.block.call(dashboard)).to be_nil
      expect(ip_throttle.block.call(dashboard)).to be_nil
    end

    it "has no key to count a keyless call by, and falls through to the source address" do
      keyless = rack_request(endpoint, "REMOTE_ADDR" => "203.0.113.9")

      expect(key_throttle.block.call(keyless)).to be_nil
      expect(ip_throttle.block.call(keyless)).to eq("203.0.113.9")
    end
  end
end
