require "rails_helper"

# Every failure on the public pixel surface leaves through one envelope. The
# anonymous controller below stands in for the real endpoints so the mapping in
# CLAUDE.md §7.3 is proven independently of any one of them.
RSpec.describe Api::Pixel::BaseController, type: :controller do
  controller do
    def index
      raise params[:raise].constantize, "boom"
    end
  end

  def envelope
    response.parsed_body["error"]
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

  # Every envelope carries the same three keys. The request id is supplied by
  # ActionDispatch::RequestId, which controller specs bypass; that it arrives
  # populated through a real middleware stack is asserted in the throttling
  # example of spec/requests/authentication_spec.rb.
  it "answers with the same three-key envelope whatever went wrong" do
    get :index, params: { raise: "Errors::OriginNotAllowed" }

    expect(envelope.keys).to contain_exactly("code", "message", "request_id")
  end
end
