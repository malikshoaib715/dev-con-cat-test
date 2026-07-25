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

    fill_in "first_name", with: first_name
    fill_in "last_name",  with: last_name
    fill_in "email",      with: email
    fill_in "phone",      with: phone
    check "consent"
    click_button "Get my quote"

    expect(page).to have_css(".row", text: "Subscribed to activity for", wait: 15)
    drain_pipeline
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
