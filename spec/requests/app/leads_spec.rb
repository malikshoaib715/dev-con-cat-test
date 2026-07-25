require "rails_helper"

RSpec.describe "App::Leads", type: :request do
  let(:solar)    { create(:account, name: "SolarPro") }
  let(:medicare) { create(:account, name: "MedicareEdge") }

  let!(:solar_lead) do
    as_tenant(solar) { create(:lead, account: solar, first_name: "Maria", last_name: "Gonzalez") }
  end

  let!(:medicare_lead) do
    as_tenant(medicare) { create(:lead, account: medicare, first_name: "Daniel", last_name: "Okafor") }
  end

  it "shows a member only their own account's leads" do
    sign_in create(:user, account: solar, role: "member")

    get app_leads_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(solar_lead.public_id)
    expect(response.body).not_to include(medicare_lead.public_id)
  end

  it "shows the other account's leads to that account's users, and only those" do
    sign_in create(:user, account: medicare, role: "member")

    get app_leads_path

    expect(response.body).to include(medicare_lead.public_id)
    expect(response.body).not_to include(solar_lead.public_id)
  end

  it "has nothing to show a platform operator, who has no tenant of their own" do
    sign_in create(:user, :super_admin)

    get app_leads_path

    expect(response).to have_http_status(:not_found)
  end

  it "sends an anonymous visitor to sign in" do
    get app_leads_path

    expect(response).to redirect_to(new_user_session_path)
  end

  describe "filtering" do
    let(:member) { create(:user, account: solar, role: "member") }

    let!(:accepted) do
      as_tenant(solar) { create(:lead, account: solar, verdict: "accept", status: "completed") }
    end

    let!(:held) do
      as_tenant(solar) { create(:lead, account: solar, status: "on_hold_insufficient_credits") }
    end

    let!(:flagged) do
      as_tenant(solar) do
        create(:lead, account: solar, verdict: "accept", status: "completed", flags: [ "soft_duplicate" ])
      end
    end

    before { sign_in member }

    it "narrows to one verdict" do
      get app_leads_path(verdict: "accept")

      expect(response.body).to include(accepted.public_id, flagged.public_id)
      expect(response.body).not_to include(held.public_id)
    end

    it "narrows to one status" do
      get app_leads_path(status: "on_hold_insufficient_credits")

      expect(response.body).to include(held.public_id)
      expect(response.body).not_to include(accepted.public_id)
    end

    it "narrows to leads carrying a flag" do
      get app_leads_path(flag: "soft_duplicate")

      expect(response.body).to include(flagged.public_id)
      expect(response.body).not_to include(accepted.public_id)
    end

    it "narrows to a date range on when the lead was submitted" do
      old_lead = as_tenant(solar) { create(:lead, account: solar, submitted_at: 10.days.ago) }

      get app_leads_path(from: 2.days.ago.to_date.to_s)

      expect(response.body).to include(accepted.public_id)
      expect(response.body).not_to include(old_lead.public_id)
    end

    it "includes a lead submitted on the closing day of the range" do
      get app_leads_path(from: Date.current.to_s, to: Date.current.to_s)

      expect(response.body).to include(accepted.public_id)
    end

    it "combines filters rather than letting the last one win" do
      get app_leads_path(verdict: "accept", flag: "soft_duplicate")

      expect(response.body).to include(flagged.public_id)
      expect(response.body).not_to include(accepted.public_id)
    end

    # A hand-edited URL is a bad query, not a server error.
    it "ignores a filter value the pipeline could never have written" do
      get app_leads_path(verdict: "definitely-not-a-verdict")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(accepted.public_id, held.public_id)
    end

    it "offers the review queue as a filtered link rather than a second page" do
      review = as_tenant(solar) { create(:lead, account: solar, verdict: "review", status: "completed") }

      get app_leads_path(verdict: "review")

      expect(response.body).to include(review.public_id)
      expect(response.body).not_to include(accepted.public_id)
    end
  end

  describe "the lead detail page" do
    before { sign_in create(:user, account: solar, role: "member") }

    it "is addressed by the id the buyer's own records use" do
      get app_lead_path(solar_lead)

      expect(response).to have_http_status(:ok)
      expect(request.path).to end_with(solar_lead.public_id)
    end

    it "reports another account's lead as missing rather than as forbidden" do
      get app_lead_path(medicare_lead)

      expect(response).to have_http_status(:not_found)
    end

    it "finds nothing when a row id is probed in place of a public one" do
      get app_lead_path(solar_lead.id)

      expect(response).to have_http_status(:not_found)
    end

    context "with a finished verification" do
      let(:lead) { as_tenant(solar) { create(:lead, account: solar, status: "completed", verdict: "reject") } }

      let!(:run) do
        as_tenant(solar) do
          Verification::RunCreator.call(lead: lead, effective_layer_keys: %w[anura duplicate_detection]).value
        end
      end

      let!(:verdict) do
        as_tenant(solar) do
          create(:consensus_verdict, account: solar, verification_run: run, verdict: "reject", score: 0,
                                     reasons: [ "duplicate of an existing customer" ],
                                     hard_stop_layer: "duplicate_detection",
                                     policy_snapshot: { "thresholds" => { "accept" => 70 } })
        end
      end

      let!(:certificate) do
        as_tenant(solar) { create(:consent_certificate, account: solar, verification_run: run, lead: lead) }
      end

      before do
        as_tenant(solar) do
          run.layer_results.find_by(layer_key: "anura")
             .update!(status: "completed", panel_verdict: "pass", verdict: "good",
                      detail: "no fraud signals", score_delta: 0,
                      started_at: 2.seconds.ago, completed_at: 1.second.ago)
          create(:visit, account: solar, pixel: lead.pixel, session_id: lead.session_id,
                         ip_address: "76.14.201.33")
          Audit::Recorder.record!(Audit::Events::LEAD_RECEIVED, subject: lead, account: solar,
                                  payload: { page_url: lead.page_url })
        end
      end

      it "names the layers this account never bought rather than leaving them blank" do
        get app_lead_path(lead)

        expect(response.body).to include("Not in plan")
        expect(response.body).to include("Voice AI")
      end

      it "shows every layer in the registry, whatever state it ended in" do
        get app_lead_path(lead)

        Layers::Registry.entries.each { |entry| expect(response.body).to include(entry.label) }
      end

      it "shows the decision, its reasons and the layer that hard-stopped it" do
        get app_lead_path(lead)

        expect(response.body).to include("duplicate of an existing customer")
        expect(response.body).to include("Hard stop")
      end

      it "keeps the policy the verdict was reached under on the page" do
        get app_lead_path(lead)

        expect(response.body).to include("Policy snapshot", "accept")
      end

      it "links the certificate to the page anybody can check it on" do
        get app_lead_path(lead)

        expect(response.body).to include(certificate.public_id)
        expect(response.body).to include(verify_certificate_path(certificate.public_id))
      end

      it "tells the story from the visit onwards, not just from the verdict" do
        get app_lead_path(lead)

        expect(response.body).to include(Audit::Events::LEAD_RECEIVED)
        expect(response.body).to include("76.14.201.33")
      end
    end
  end

  describe "re-verifying" do
    let(:pixel) { as_tenant(solar) { create(:pixel, account: solar, enabled_layers: [ "anura" ]) } }

    let(:held) do
      as_tenant(solar) do
        create(:lead, account: solar, pixel: pixel, status: "on_hold_insufficient_credits")
      end
    end

    before do
      as_tenant(solar) { create(:layer_policy, account: solar, layer_key: "anura", enabled: true) }
      create(:layer_definition, key: "anura", cost_credits: 3)
    end

    it "restarts a held verification once an admin has topped the account up" do
      solar.update!(credit_balance: 10)
      sign_in create(:user, account: solar, role: "account_admin")

      post reverify_app_lead_path(held)

      expect(response).to redirect_to(app_lead_path(held))
      expect(flash[:notice]).to eq("Verification restarted.")
      expect(held.reload.status).to eq("verifying")
    end

    it "says so, and keeps the lead held, when the balance is still short" do
      solar.update!(credit_balance: 0)
      sign_in create(:user, account: solar, role: "account_admin")

      post reverify_app_lead_path(held)

      expect(flash[:alert]).to match(/Insufficient credits/)
      expect(held.reload.status).to eq("on_hold_insufficient_credits")
    end

    it "refuses a lead that is not waiting on anybody" do
      lead = as_tenant(solar) { create(:lead, account: solar, status: "completed", verdict: "accept") }
      sign_in create(:user, account: solar, role: "account_admin")

      post reverify_app_lead_path(lead)

      expect(flash[:alert]).to match(/not waiting to be verified/)
    end

    # Spending an account's credits is an administrative act, so the read-only
    # role cannot do it — and cannot see the button either.
    it "refuses a member, who is read-only" do
      solar.update!(credit_balance: 10)
      sign_in create(:user, account: solar, role: "member")

      post reverify_app_lead_path(held)

      expect(response).to have_http_status(:forbidden)
      expect(held.reload.status).to eq("on_hold_insufficient_credits")
    end

    it "offers a member no button to press" do
      solar.update!(credit_balance: 10)
      sign_in create(:user, account: solar, role: "member")

      get app_lead_path(held)

      expect(response.body).not_to include(reverify_app_lead_path(held))
    end

    it "offers an admin the button on a held lead" do
      solar.update!(credit_balance: 10)
      sign_in create(:user, account: solar, role: "account_admin")

      get app_lead_path(held)

      expect(response.body).to include(reverify_app_lead_path(held))
    end

    it "reports another account's lead as missing rather than re-verifying it" do
      sign_in create(:user, account: medicare, role: "account_admin")

      post reverify_app_lead_path(held)

      expect(response).to have_http_status(:not_found)
      expect(held.reload.status).to eq("on_hold_insufficient_credits")
    end
  end

  describe "searching" do
    let!(:searchable) do
      as_tenant(solar) do
        create(:lead, account: solar, first_name: "Patricia", last_name: "Whitfield",
                      email: "p.whitfield@example.com", email_normalized: "p.whitfield@example.com",
                      phone: "+16465550193", phone_normalized: "+16465550193")
      end
    end

    before { sign_in create(:user, account: solar, role: "member") }

    # A buyer types the number the way their call sheet prints it; the normalizer
    # is what makes that the same search as the stored E.164 form.
    it "finds a lead by a phone number typed the way a human writes one" do
      get app_leads_path(q: "(646) 555-0193")

      expect(response.body).to include(searchable.public_id)
      expect(response.body).not_to include(solar_lead.public_id)
    end

    it "finds a lead by email address, whatever case it is typed in" do
      get app_leads_path(q: "P.Whitfield@Example.com")

      expect(response.body).to include(searchable.public_id)
    end

    it "finds a lead by part of a name" do
      get app_leads_path(q: "whitfi")

      expect(response.body).to include(searchable.public_id)
      expect(response.body).not_to include(solar_lead.public_id)
    end

    it "finds a lead by first and last name together" do
      get app_leads_path(q: "Patricia Whitfield")

      expect(response.body).to include(searchable.public_id)
    end

    it "never reaches into another account, however well the term matches" do
      twin = as_tenant(medicare) do
        create(:lead, account: medicare, first_name: "Patricia", last_name: "Whitfield",
                      phone: "+16465550193", phone_normalized: "+16465550193")
      end

      get app_leads_path(q: "+16465550193")

      expect(response.body).to include(searchable.public_id)
      expect(response.body).not_to include(twin.public_id)
    end
  end
end
