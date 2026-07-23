require "rails_helper"

# Every failure on the public pixel surface leaves through one envelope. The
# anonymous controller below stands in for the real endpoints so the full error
# mapping is proven independently of any one of them.
RSpec.describe Api::Pixel::BaseController, type: :controller do
  controller do
    def index
      raise params[:raise].constantize, "boom"
    end
  end

  def envelope
    response.parsed_body["error"]
  end

  # This spec is about the envelope, not about who may reach an action: the key
  # and origin checks are proven end to end in spec/requests/api/pixel/.
  before do
    allow(controller).to receive(:authenticate_pixel!)
    allow(controller).to receive(:enforce_origin!)
  end


  it "answers an unknown or inactive pixel key with 401" do
    get :index, params: { raise: "Errors::PixelNotAuthorized" }

    expect(response).to have_http_status(:unauthorized)
    expect(envelope["code"]).to eq("pixel_not_authorized")
  end

  it "answers a disallowed origin with 403" do
    get :index, params: { raise: "Errors::OriginNotAllowed" }

    expect(response).to have_http_status(:forbidden)
    expect(envelope["code"]).to eq("origin_not_allowed")
  end

  it "answers insufficient credits with 402" do
    get :index, params: { raise: "Errors::InsufficientCredits" }

    expect(response).to have_http_status(:payment_required)
    expect(envelope["code"]).to eq("insufficient_credits")
  end

  it "answers a domain validation failure with 422" do
    get :index, params: { raise: "Errors::ValidationFailed" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(envelope["code"]).to eq("validation_failed")
  end

  it "answers a missing record with 404" do
    get :index, params: { raise: "ActiveRecord::RecordNotFound" }

    expect(response).to have_http_status(:not_found)
    expect(envelope["code"]).to eq("not_found")
  end

  # A number too large for its column is the visitor's input, not our bug, and
  # §7.6 rules out answering a buyer's landing page with a 500 for it.
  it "answers a value outside its column's range with 422" do
    get :index, params: { raise: "ActiveModel::RangeError" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(envelope["code"]).to eq("value_out_of_range")
  end

  it "answers a body it cannot parse with 400" do
    get :index, params: { raise: "ActionDispatch::Http::Parameters::ParseError" }

    expect(response).to have_http_status(:bad_request)
    expect(envelope["code"]).to eq("malformed_body")
  end

  # ParameterMissing is Rails' exception and carries no `code` of its own, so a
  # handler that asked it for one would raise inside itself and take the request
  # out through the catch-all it exists to prevent.
  it "answers a missing parameter with 422 rather than raising inside the handler" do
    get :index, params: { raise: "ActionController::ParameterMissing" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(envelope["code"]).to eq("parameter_missing")
  end

  it "answers anything unexpected with 500 and never leaks the internals" do
    get :index, params: { raise: "NoMethodError" }

    expect(response).to have_http_status(:internal_server_error)
    expect(envelope["code"]).to eq("internal_error")
    expect(envelope["message"]).to eq("Something went wrong.")
    expect(response.body).not_to include("boom")
  end

  it "audits an unexpected failure so it is queryable later" do
    get :index, params: { raise: "NoMethodError" }

    events = ActsAsTenant.without_tenant { AuditEvent.of_type(Audit::Events::API_REQUEST_REJECTED) }
    expect(events.first.payload["error_class"]).to eq("NoMethodError")
  end

  # §6's rule is that if it happened there is a row for it. A stolen snippet run
  # from a domain its owner never allowed, or a key that no longer exists, is
  # exactly what a buyer asks about weeks later, and it used to leave no trace.
  describe "the trail a refused call leaves" do
    def rejections
      ActsAsTenant.without_tenant { AuditEvent.of_type(Audit::Events::API_REQUEST_REJECTED) }
    end

    {
      "Errors::PixelNotAuthorized" => [ "pixel_not_authorized", 401 ],
      "Errors::OriginNotAllowed" => [ "origin_not_allowed", 403 ],
      "Errors::ValidationFailed" => [ "validation_failed", 422 ],
      "ActionDispatch::Http::Parameters::ParseError" => [ "malformed_body", 400 ],
      "ActiveModel::RangeError" => [ "value_out_of_range", 422 ],
      "ActiveRecord::RecordNotFound" => [ "not_found", 404 ]
    }.each do |error_class, (code, status)|
      it "records the #{status} it answered #{error_class.demodulize} with" do
        get :index, params: { raise: error_class }

        expect(rejections.sole.payload).to include("code" => code, "status" => status)
      end
    end

    it "records the path, and never the body that was posted" do
      get :index, params: { raise: "Errors::OriginNotAllowed", email: "visitor@example.com" }

      payload = rejections.sole.payload
      expect(payload).to have_key("path")
      expect(payload.to_json).not_to include("visitor@example.com")
    end

    # Not a rejection: the call was understood and the balance was the problem,
    # which credits.insufficient and lead.on_hold already record in full.
    it "leaves an insufficient balance to the events that describe it properly" do
      get :index, params: { raise: "Errors::InsufficientCredits" }

      expect(rejections).to be_empty
    end
  end

  # Every envelope carries the same three keys. The request id is supplied by
  # ActionDispatch::RequestId, which controller specs bypass; that it arrives
  # populated through a real middleware stack is asserted in the throttling
  # example of spec/requests/authentication_spec.rb.
  it "answers with the same three-key envelope whatever went wrong" do
    get :index, params: { raise: "Errors::OriginNotAllowed" }

    expect(envelope.keys).to contain_exactly("code", "message", "request_id")
  end
end
