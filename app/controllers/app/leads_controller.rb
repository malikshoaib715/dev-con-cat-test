# frozen_string_literal: true

module App
  # The buyer's CRM: every lead their pixels captured, and what the pipeline
  # decided about each one.
  class LeadsController < BaseController
    include Pagy::Backend

    def index
      @pagy, @leads = pagy(filtered_leads)
    end

    private

    # Named scopes compose; the controller only decides which of them apply. An
    # unrecognised filter value is dropped rather than raising: a hand-edited URL
    # is a bad query, not a server error.
    def filtered_leads
      leads = policy_scope(current_account.leads).recent_first.includes(:pixel, :consensus_verdict)
      leads = leads.with_verdict(filters[:verdict]) if filters[:verdict]
      leads = leads.with_status(filters[:status])   if filters[:status]
      leads = leads.flagged_with(filters[:flag])    if filters[:flag]
      leads = leads.submitted_from(filters[:from])  if filters[:from]
      leads = leads.submitted_to(filters[:to])      if filters[:to]
      leads = leads.search(filters[:q])             if filters[:q]
      leads
    end

    def filters
      @filters ||= {
        verdict: permitted(params[:verdict], Lead::VERDICTS),
        status: permitted(params[:status], Lead::STATUSES),
        flag: permitted(params[:flag], Consensus::Engine::FLAGS),
        from: timestamp(params[:from]),
        to: end_of_day(params[:to]),
        q: params[:q].presence
      }
    end

    def permitted(value, allowed)
      value.presence_in(allowed)
    end

    def timestamp(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, RangeError
      nil
    end

    # A buyer asking for leads up to the 3rd means the whole of the 3rd, not
    # midnight at the start of it.
    def end_of_day(value)
      timestamp(value)&.end_of_day
    end
  end
end
