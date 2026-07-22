require "rails_helper"

# The browser harness, exercised end to end: a real Chrome, a real form post
# through Devise, a real tenant-scoped page. It is deliberately in place from
# phase 1 so the demo system spec in chunk 4.4 is not the first time selenium
# runs.
RSpec.describe "Signing in", type: :system do
  let(:account) { create(:account, name: "SolarPro Leads LLC") }

  let!(:user) do
    create(:user, account: account, name: "Dana Whitfield",
                  email: "dana@solarpro.example", password: "Sup3rPixel!pw")
  end

  let!(:lead) do
    as_tenant(account) { create(:lead, account: account, first_name: "Maria", last_name: "Gonzalez") }
  end

  it "takes a buyer from the sign-in screen to their own leads and back out" do
    visit root_path

    expect(page).to have_content("Sign in")

    fill_in "Email", with: "dana@solarpro.example"
    fill_in "Password", with: "Sup3rPixel!pw"
    click_button "Sign in"

    expect(page).to have_content("Leads")
    expect(page).to have_content("Maria Gonzalez")
    expect(page).to have_content(lead.public_id)
    expect(page).to have_content("SolarPro Leads LLC")

    click_button "Sign out"

    expect(page).to have_content("Sign in")
  end

  it "refuses a wrong password without revealing whether the mailbox exists" do
    visit root_path

    fill_in "Email", with: "dana@solarpro.example"
    fill_in "Password", with: "not-the-password"
    click_button "Sign in"

    expect(page).to have_content("Invalid email or password.")
    expect(page).to have_no_content("Maria Gonzalez")
  end
end
