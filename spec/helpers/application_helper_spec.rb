require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#verdict_badge" do
    it "names the verdict" do
      expect(helper.verdict_badge("accept")).to include("ACCEPT")
    end

    it "reads as pending when a lead has not been decided yet" do
      expect(helper.verdict_badge(nil)).to include("PENDING")
    end
  end

  describe "#status_badge" do
    it "warns in amber on a lead held for want of credits" do
      badge = helper.status_badge("on_hold_insufficient_credits")

      expect(badge).to include("On hold insufficient credits")
      expect(badge).to include("amber")
    end
  end

  describe "#layer_state_badge" do
    # Tenant-owned rows refuse to exist outside a tenant, even unsaved ones.
    around { |example| as_tenant(create(:account)) { example.run } }

    # Only the two columns the badge reads: a row is enough to render, and does
    # not need a run behind it.
    def layer_result(status, panel_verdict: nil)
      LayerResult.new(status: status, panel_verdict: panel_verdict)
    end

    it "says a layer outside the plan was never bought, rather than leaving it blank" do
      expect(helper.layer_state_badge(layer_result("not_enabled"))).to include("Not in plan")
    end

    it "says a layer with nothing to judge is not applicable" do
      expect(helper.layer_state_badge(layer_result("not_applicable"))).to include("N/A")
    end

    # The distinction the certificate exists to make: a vendor that never answered
    # is unavailable, and is never coloured as a check that passed.
    it "shows an errored layer as unavailable in amber, not as a pass" do
      badge = helper.layer_state_badge(layer_result("errored"))

      expect(badge).to include("Unavailable")
      expect(badge).to include("amber")
      expect(badge).not_to include("emerald")
    end

    it "colours a completed layer by what it decided" do
      badge = helper.layer_state_badge(layer_result("completed", panel_verdict: "fail"))

      expect(badge).to include("FAIL")
      expect(badge).to include("rose")
    end

    it "shows a layer still in flight as waiting" do
      expect(helper.layer_state_badge(layer_result("pending"))).to include("Waiting")
    end
  end

  describe "#runway_text" do
    it "reports an account that spends nothing as never running out" do
      expect(helper.runway_text(Float::INFINITY)).to eq("∞")
    end

    it "rounds a real runway to a tenth of a day" do
      expect(helper.runway_text(0.83333)).to eq("0.8 days")
    end
  end
end
