require "rails_helper"

RSpec.describe "App::Pixels", type: :request do
  let(:account) { create(:account, name: "SolarPro") }
  let(:other_account) { create(:account, name: "MedicareEdge") }
  let(:admin) { create(:user, account: account, role: "account_admin") }
  let(:member) { create(:user, account: account, role: "member") }

  # The account's plan: everything except voice, which is the seeded SolarPro
  # shape and the reason "not in plan" has something to render.
  let(:purchased_keys) { Layers::Registry.keys - [ "voice" ] }

  let!(:pixel) do
    as_tenant(account) { create(:pixel, account: account, name: "Quote page", enabled_layers: purchased_keys) }
  end

  before do
    load_layer_definitions
    purchased_keys.each do |layer_key|
      as_tenant(account) { create(:layer_policy, account: account, layer_key: layer_key, enabled: true) }
    end
  end

  describe "reading" do
    it "lists an account's own pixels with what each verification costs" do
      sign_in member

      get app_pixels_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Quote page", pixel.public_id)
    end

    it "shows the snippet the buyer is meant to paste" do
      sign_in member

      get app_pixel_path(pixel)

      expect(response.body).to include(ERB::Util.html_escape(
                                         Pixels::SnippetGenerator.call(pixel: pixel, endpoint_base: "http://www.example.com")
                                       ))
    end

    it "marks a layer the plan does not include as unavailable rather than merely off" do
      sign_in member

      get app_pixel_path(pixel)

      expect(response.body).to include("not in plan")
    end

    it "answers another account's pixel as missing, never as forbidden" do
      other_pixel = as_tenant(other_account) { create(:pixel, account: other_account) }
      sign_in member

      get app_pixel_path(other_pixel)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "writing" do
    let(:attributes) do
      { name: "Landing page B", active: "1",
        allowed_domains: "buyer.example.com\n  \nsecond.example.com\n",
        enabled_layers: [ "anura", "dnc" ] }
    end

    it "lets an account admin create a pixel and records what changed" do
      sign_in admin

      expect { post app_pixels_path, params: { pixel: attributes } }
        .to change { as_tenant(account) { Pixel.count } }.by(1)

      created = as_tenant(account) { Pixel.order(:created_at).last }
      expect(created.allowed_domains).to eq([ "buyer.example.com", "second.example.com" ])
      expect(response).to redirect_to(app_pixel_path(created))
    end

    it "leaves an audit row naming the fields that changed" do
      sign_in admin

      post app_pixels_path, params: { pixel: attributes }

      event = ActsAsTenant.without_tenant { AuditEvent.of_type(Audit::Events::PIXEL_CREATED).last }
      expect(event.payload["changes"]).to include("name", "allowed_domains")
      expect(event.payload["changes"]).not_to include("updated_at")
    end

    it "records an update against the pixel it changed" do
      sign_in admin

      patch app_pixel_path(pixel), params: { pixel: attributes.merge(name: "Renamed") }

      event = ActsAsTenant.without_tenant { AuditEvent.of_type(Audit::Events::PIXEL_UPDATED).last }
      expect(event.subject_id).to eq(pixel.id)
      expect(event.payload.dig("changes", "name")).to eq([ "Quote page", "Renamed" ])
    end

    # The form only offers purchased layers, but a form is the visitor's to edit.
    it "refuses to enable a layer the account has not bought, however it is posted" do
      sign_in admin

      patch app_pixel_path(pixel), params: { pixel: attributes.merge(enabled_layers: %w[anura voice]) }

      expect(pixel.reload.enabled_layers).to eq([ "anura" ])
    end

    it "ignores an attempt to post a pixel into another account" do
      sign_in admin

      post app_pixels_path, params: { pixel: attributes.merge(account_id: other_account.id) }

      created = as_tenant(account) { Pixel.order(:created_at).last }
      expect(created.account_id).to eq(account.id)
    end

    it "re-renders the form when the pixel is invalid rather than losing the buyer's input" do
      sign_in admin

      post app_pixels_path, params: { pixel: attributes.merge(name: "") }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("stopped this from saving")
    end
  end

  describe "roles" do
    it "refuses a member the right to create a pixel" do
      sign_in member

      post app_pixels_path, params: { pixel: { name: "Nope" } }

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a member the right to change one" do
      sign_in member

      patch app_pixel_path(pixel), params: { pixel: { name: "Nope" } }

      expect(response).to have_http_status(:forbidden)
      expect(pixel.reload.name).to eq("Quote page")
    end

    it "offers a member no way to create one" do
      sign_in member

      get app_pixels_path

      expect(response.body).not_to include("New pixel")
    end
  end

  describe "deleting" do
    it "removes a pixel that has captured nothing" do
      sign_in admin

      expect { delete app_pixel_path(pixel) }.to change { as_tenant(account) { Pixel.count } }.by(-1)
    end

    # The leads are evidence of where they came from; the refusal is shown rather
    # than rescued away.
    it "refuses to remove a pixel that leads came through, and says why" do
      as_tenant(account) { create(:lead, account: account, pixel: pixel) }
      sign_in admin

      delete app_pixel_path(pixel)

      expect(as_tenant(account) { Pixel.count }).to eq(1)
      expect(response).to redirect_to(app_pixel_path(pixel))
      expect(flash[:alert]).to be_present
    end
  end
end
