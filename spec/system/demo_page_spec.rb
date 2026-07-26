require "rails_helper"

# The proof that the whole loop works: a real browser loads the real snippet, the
# pixel posts a real lead, ten layer jobs run, and the panel fills from the audit
# spine over a real socket. Everything phases 1-3 built is exercised here without
# a single stub.
RSpec.describe "The demo landing page", :seeded_world, type: :system do
  # Deliberately NOT the inline adapter. Running the layers inside the POST would
  # finish the whole verification before the browser had finished subscribing, and
  # every frame would be broadcast to nobody — the page would pass a test while
  # proving nothing. Instead the jobs are held until the socket has confirmed, and
  # only then released, so what the panel renders genuinely arrived over the wire.
  def submit_lead(first_name:, last_name:, email:, phone:)
    visit "/demo"

    fill_lead_form(first_name: first_name, last_name: last_name, email: email, phone: phone)
    check "consent"
    click_button "Get my quote"

    expect(page).to have_css(".row", text: "Subscribed to activity for", wait: 15)
    drain_pipeline
  end

  def fill_lead_form(first_name:, last_name:, email:, phone:)
    fill_in "first_name", with: first_name
    fill_in "last_name",  with: last_name
    fill_in "email",      with: email
    fill_in "phone",      with: phone
  end

  # Draining once runs the layer jobs; the last of them enqueues the finalizer,
  # which is only in the queue by then — hence draining until it is genuinely
  # empty rather than once.
  def drain_pipeline
    perform_enqueued_jobs while enqueued_jobs.any?
  end

  # The panel's verdict banner, which the page reveals only once the final frame
  # has arrived over the wire.
  def final_banner
    find("#final", visible: true)
  end

  it "runs a lead we have never seen through every layer and accepts it" do
    submit_lead(first_name: "Alex", last_name: "Fielding",
                email: "alex.fielding@example.com", phone: "+13105550101")

    expect(page).to have_css(".row .layer", text: "DNC / Callback", wait: 15)
    expect(page).to have_css(".row .layer", text: "Anura")
    expect(final_banner).to have_text("ACCEPT")
  end

  # Robert Vance is seeded under an account that never bought the blacklist layer,
  # where his rejection comes from DNC alone. Replayed here he goes through
  # SolarPro's pixel, which does buy it — so both layers light up red and the
  # verdict is the same. That the answer survives the change of account is the
  # point: the panel is showing one buyer's enabled layers, not a fixed script.
  it "hard-stops a persona on the do-not-call list and shows which layer did it" do
    submit_lead(first_name: "Robert", last_name: "Vance",
                email: "rvance.legal@protonmail.example", phone: "+18185550199")

    # The badge's own text is upper-cased by the page's stylesheet, so the class
    # is what is asserted on — the row is red because the layer failed.
    expect(page).to have_css(".row", text: "DNC / Callback", wait: 15)
    within(".row", text: "DNC / Callback") { expect(page).to have_css(".badge.b-fail") }
    expect(final_banner).to have_text("REJECT")
  end

  it "streams the layers one at a time rather than in a single lump" do
    submit_lead(first_name: "Alex", last_name: "Fielding",
                email: "alex.fielding@example.com", phone: "+13105550102")

    expect(page).to have_css(".row", minimum: 5, wait: 15)
    expect(page).to have_css("#final", visible: true, wait: 15)
    # Voice is the one module SolarPro does not buy, so it never reports at all —
    # a layer the buyer did not pay for is absent, not a row saying "skipped".
    expect(page).to have_css(".row .layer", text: "TrustedForm")
    expect(page).to have_no_css(".row .layer", text: "Voice AI")
  end

  # The browser is the first gate: a visitor who never gave affirmative consent
  # is refused on the page itself — no request leaves, no lead row exists, no
  # credit is spent. Once the box is ticked the same identity sails through, and
  # the payload carries the tick as a native form post would: "consent" => "on".
  it "refuses the submission until the consent box is ticked" do
    visit "/demo"
    fill_lead_form(first_name: "Alex", last_name: "Fielding",
                   email: "alex.gated@example.com", phone: "+13105550103")
    click_button "Get my quote"

    expect(page.evaluate_script("document.querySelector('[name=consent]').validity.valueMissing")).to be(true)
    expect(page).to have_no_css(".row", text: "Subscribed to activity for")
    expect(ActsAsTenant.without_tenant { Lead.exists?(email: "alex.gated@example.com") }).to be(false)

    check "consent"
    click_button "Get my quote"
    expect(page).to have_css(".row", text: "Subscribed to activity for", wait: 15)
    drain_pipeline
    expect(final_banner).to have_text("ACCEPT")

    payload = ActsAsTenant.without_tenant { Lead.find_by!(email: "alex.gated@example.com").raw_payload }
    expect(payload).to include("consent" => "on")
  end

  # The pixel serves every buyer's page, not just ours — and not every page
  # marks its consent box `required`. Emulating one that does not: the box is
  # left unticked, the submission goes through, and the payload must record
  # that state as a native post would — no "consent" key at all. A checkbox's
  # `.value` reads "on" whether or not it is ticked; only the serializer's
  # checked-guard stands between that DOM quirk and fabricated consent
  # evidence, which is the one lie this product exists to prevent.
  it "records an unticked box as absent when the host page does not require it" do
    visit "/demo"
    page.execute_script(%(document.querySelector('[name="consent"]').removeAttribute("required")))
    fill_lead_form(first_name: "Alex", last_name: "Fielding",
                   email: "alex.unticked@example.com", phone: "+13105550104")
    click_button "Get my quote"
    expect(page).to have_css(".row", text: "Subscribed to activity for", wait: 15)
    drain_pipeline
    expect(final_banner).to have_text("ACCEPT")

    payload = ActsAsTenant.without_tenant { Lead.find_by!(email: "alex.unticked@example.com").raw_payload }
    expect(payload).to include("email" => "alex.unticked@example.com")
    expect(payload).not_to have_key("consent")
  end

  # A repeat submission from an unreloaded page carries the session id the first
  # one did, so the server settles it against the lead it already has — one
  # verification, one charge. The panel is then about to replay that lead's
  # history, which paints the same layers and the same banner as a fresh run, so
  # an unannounced replay is indistinguishable from a second verification that
  # happened to agree. It says which one it is.
  it "says when a resubmission is the original lead rather than a new one" do
    submit_lead(first_name: "Alex", last_name: "Fielding",
                email: "alex.replay@example.com", phone: "+13105550105")
    expect(final_banner).to have_text("ACCEPT")
    leads_before = ActsAsTenant.without_tenant { Lead.count }

    click_button "Get my quote"

    expect(page).to have_css(".row", text: "already submitted — showing the original verification",
                                     wait: 15)
    drain_pipeline
    expect(ActsAsTenant.without_tenant { Lead.count }).to eq(leads_before)
  end

  # The first of the two gates on an unusable number. This one is a courtesy —
  # the visitor's own browser, which an author of leads can simply not run — and
  # the server keeps the authoritative one: spec/services/verification/
  # finalizer_spec.rb proves a junk number reaching the API is never accepted.
  it "refuses a phone field with no phone number in it" do
    visit "/demo"
    fill_lead_form(first_name: "Alex", last_name: "Fielding",
                   email: "alex.junk@example.com", phone: ",dc kwc qkcjn q")
    check "consent"
    click_button "Get my quote"

    expect(page.evaluate_script("document.querySelector('[name=phone]').validity.patternMismatch"))
      .to be(true)
    expect(page).to have_no_css(".row", text: "Subscribed to activity for")
    expect(ActsAsTenant.without_tenant { Lead.exists?(email: "alex.junk@example.com") }).to be(false)
  end

  it "lists the seeded personas with the verdicts the engine derived for them" do
    visit "/demo"

    expect(page).to have_css(".persona-table tbody tr", count: 12)
    expect(page).to have_css(".persona-table tbody tr", text: "L-1005")
    expect(page).to have_css(".persona-table tbody tr", text: "+18185550199")
    within(".persona-table tbody tr", text: "L-1001") { expect(page).to have_css(".badge.b-pass") }
    within(".persona-table tbody tr", text: "L-1005") { expect(page).to have_css(".badge.b-fail") }
  end

  it "serves the buyer's own page, not the dashboard, and asks nobody to sign in" do
    visit "/demo"

    expect(page).to have_text("Get your free solar savings quote")
    expect(page).to have_no_text("Sign in")
  end
end
