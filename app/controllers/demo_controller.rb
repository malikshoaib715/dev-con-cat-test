# frozen_string_literal: true

# The assignment's landing page, served by the app and wired to the real pipeline.
#
# Public and untenanted, exactly like the buyer funnel it stands in for: a visitor
# filling in a solar quote form has no account with us. The pixel key in the
# snippet is what binds the submission to an account.
class DemoController < ApplicationController
  DEMO_PIXEL_PUBLIC_ID = "px_9f2a01"

  skip_before_action :authenticate_user!, :set_current_tenant

  # The buyer's page is their own document, not something rendered inside our
  # dashboard chrome.
  layout false

  def show
    @pixel = demo_pixel
    return render "demo/unseeded", status: :not_found if @pixel.nil?

    @personas = personas
  end

  private

  # No tenant on a public page, and none needed: this is a lookup by a constant
  # public id, not a scoped query on a visitor's behalf.
  def demo_pixel
    ActsAsTenant.without_tenant { Pixel.find_by(public_id: DEMO_PIXEL_PUBLIC_ID) }
  end

  # The cheat sheet is the engine's own output, not a table of copy: each persona
  # carries the verdict the real pipeline derived for it during seeding, so typing
  # one of these identities into the form replays a scenario the reader can check
  # against what the panel then shows.
  #
  # Loaded here rather than handed to the view as a relation: a lazy relation
  # would run its query during rendering, outside the block that permits it to
  # cross accounts, and every persona would vanish behind a tenancy error.
  def personas
    ActsAsTenant.without_tenant do
      Lead.seeded_personas
          .where.not(verdict: nil)
          .includes(verification_run: :consensus_verdict)
          .order(:public_id)
          .to_a
    end
  end
end
