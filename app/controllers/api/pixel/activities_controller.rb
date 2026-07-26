# frozen_string_literal: true

module Api
  module Pixel
    # The panel's fallback transport. A page whose socket died — a proxy that
    # strips WebSockets, a phone that changed network, five failed reconnects —
    # polls here instead and sees exactly the same frames, because both transports
    # render through Realtime::PanelFrame.
    #
    # Authorised differently from the rest of this namespace, and that is the
    # point: there is no pixel key on a page that is only reading back its own
    # verification. The stream token is the capability, exactly as on the channel,
    # and it has to name the lead being asked for.
    class ActivitiesController < BaseController
      skip_before_action :authenticate_pixel!, :enforce_origin!

      PAGE_LIMIT = 100

      def show
        return render_invalid_token if authorized_lead_public_id != params[:id]

        ActsAsTenant.with_tenant(lead.account) { render json: activity }
      end

      private

      def authorized_lead_public_id
        Realtime::StreamToken.lead_public_id(params[:token])
      end

      # No tenant is set on this request — the token is what establishes one, the
      # same way the pixel key does everywhere else in this namespace.
      def lead
        @lead ||= ActsAsTenant.without_tenant { Lead.find_by!(public_id: params[:id]) }
      end

      # The cursor advances past every event examined, not just the ones that
      # rendered — most of the spine is not a panel frame, and a cursor that only
      # moved for frames would re-read the same lifecycle events on every poll and
      # never get past a run whose latest events are all unrenderable.
      def activity
        frames = events.filter_map { |event| Realtime::PanelFrame.for(event) }
        cursor = events.last&.id || since

        { events: frames, cursor: cursor, done: verdict_delivered?(cursor) }
      end

      # Capped: this is a public endpoint and an unbounded read is a free way to
      # make us work. A verification produces far fewer events than this, so the
      # cap only ever bites on a client that has been away.
      def events
        @events ||= AuditEvent.for_subject(lead).after_id(since).limit(PAGE_LIMIT).to_a
      end

      # Tells the poller it can stop. True only once the verdict is in the client's
      # hands — either in this page or in one it already read — so a truncated page
      # keeps it polling rather than leaving it waiting forever on a frame it never
      # received.
      def verdict_delivered?(cursor)
        AuditEvent.for_subject(lead).of_type(Audit::Events::VERDICT_ISSUED).up_to_id(cursor).exists?
      end

      def since
        params[:since].to_i
      end

      # Never a 404, even for a lead that does not exist: a page holding no valid
      # capability is not told which ids are real.
      def render_invalid_token
        render_rejection code: "stream_token_invalid",
                         message: "A valid stream token for this lead is required.",
                         status: :unauthorized
      end
    end
  end
end
