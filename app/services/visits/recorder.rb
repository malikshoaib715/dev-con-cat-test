# frozen_string_literal: true

module Visits
  # Records the site-visit beacon the pixel fires on page load. Its IP is the
  # only thing that later lets the VPN layer say "browsed from a residential
  # address, submitted through a VPN".
  #
  # Idempotent by the unique (pixel_id, session_id) index: the beacon is sent
  # with `keepalive` from a page that may be unloading, so it can arrive twice.
  # The first one wins and a retry is a no-op — never a 500, and never a second
  # event on the timeline.
  class Recorder < ApplicationService
    # The panel renders field focus/blur churn client-side and only this summary
    # is ever persisted (§6). Capping it is the same protection one level down: a
    # looping or hostile page must not be able to write an unbounded document into
    # a single row. Truncated rather than refused, because a beacon that fails is
    # a beacon that breaks somebody's landing page.
    MAX_INTERACTIONS = 100

    def initialize(pixel:, attributes:, ip_address:, user_agent:)
      @pixel = pixel
      @attributes = attributes
      @ip_address = ip_address
      @user_agent = user_agent
    end

    def call
      existing = @pixel.visits.find_by(session_id: session_id)
      return success(existing) if existing

      success(record_first_beacon)
    rescue ActiveRecord::RecordNotUnique
      # A concurrent beacon won the insert; its row is the one that counts.
      success(@pixel.visits.find_by!(session_id: session_id))
    end

    private

    def record_first_beacon
      visit = @pixel.visits.create!(visit_attributes)
      Audit::Recorder.record!(
        Audit::Events::PIXEL_VISIT_RECORDED,
        subject: visit,
        payload: { page_url: visit.page_url, referrer: visit.referrer }
      )
      visit
    end

    # Address and user agent come from the connection, never from the body: a
    # payload-supplied IP would make the visit-vs-submit comparison trivial to
    # defeat.
    def visit_attributes
      {
        session_id: session_id,
        page_url: @attributes[:page_url],
        referrer: @attributes[:referrer],
        interactions: Array(@attributes[:interactions]).first(MAX_INTERACTIONS),
        started_at: @attributes[:started_at].presence || Time.current,
        ip_address: @ip_address,
        user_agent: @user_agent
      }
    end

    def session_id
      @attributes.fetch(:session_id)
    end
  end
end
