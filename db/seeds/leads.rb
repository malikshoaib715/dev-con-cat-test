module Seeds
  # The twelve fixture leads, ingested through the real service and verified by the
  # real pipeline. Nothing here tells the engine what to decide: `expected_verdict`
  # is never passed into the application at all — it is read back out of the
  # fixture file at report time, and comparing the two is the whole point.
  #
  # `::Leads` throughout, because inside `Seeds::Leads` a bare `Leads` resolves to
  # this module rather than to the application's.
  module Leads
    # Fixture hints, and what each one means once derived. REJECT_DUPLICATE is a
    # rejection that must have come from the duplicate layer specifically, so it
    # carries the flag it has to produce.
    HINTS = {
      "ACCEPT" => { verdict: "accept", flag: nil },
      "REVIEW" => { verdict: "review", flag: nil },
      "REJECT" => { verdict: "reject", flag: nil },
      "REJECT_DUPLICATE" => { verdict: "reject", flag: "duplicate" }
    }.freeze

    Row = Data.define(:lead_ref, :derived, :score, :via, :flags, :hint) do
      def matches?
        expected = HINTS.fetch(hint)
        derived == expected.fetch(:verdict) && (expected.fetch(:flag).nil? || flags.include?(expected.fetch(:flag)))
      end
    end

    def self.load!
      inline_pipeline do
        MockData.read("leads.json").fetch("leads").each { |attributes| ingest(attributes) }
      end

      puts "  leads: #{ActsAsTenant.without_tenant { Lead.count }}"
    end

    # Seeding must never depend on a Sidekiq worker being up, nor race one that is:
    # under the inline adapter the fan-out runs in this process, the last layer
    # walks through the completion gate, and finalization happens before the next
    # lead is ingested. The simulated vendor latency exists to make the live demo
    # trickle and would only make seeding slow.
    def self.inline_pipeline
      adapter = ActiveJob::Base.queue_adapter
      latency = Rails.application.config.x.providers.simulated_latency
      ActiveJob::Base.queue_adapter = :inline
      Rails.application.config.x.providers.simulated_latency = false

      yield
    ensure
      ActiveJob::Base.queue_adapter = adapter
      Rails.application.config.x.providers.simulated_latency = latency
    end

    def self.ingest(attributes)
      lead_ref = attributes.fetch("lead_id")
      account = Account.find_by!(public_id: attributes.fetch("account_id"))

      ActsAsTenant.with_tenant(account) do
        next if Lead.exists?(public_id: lead_ref)

        pixel = Pixel.find_by!(public_id: attributes.fetch("pixel_id"))
        establish_context(account, pixel, lead_ref)
        record_visit(pixel, attributes, lead_ref)
        accept(pixel, attributes, lead_ref)
      end
    ensure
      Current.reset
    end

    # What a request would have stamped, so the seeded events carry the same
    # correlation the live ones do and a lead's timeline stitches together.
    def self.establish_context(account, pixel, lead_ref)
      Current.account = account
      Current.pixel = pixel
      Current.session_id = session_id_for(lead_ref)
      Current.ip_address = nil
    end

    # The page load that preceded the submission. Its address is what later lets
    # the VPN layer say "browsed from home, submitted through an anonymizer".
    def self.record_visit(pixel, attributes, lead_ref)
      Visits::Recorder.call(
        pixel: pixel,
        attributes: {
          session_id: session_id_for(lead_ref),
          page_url: attributes.fetch("landing_page_url"),
          started_at: captured_at(attributes) - (attributes.fetch("form_dwell_ms") / 1000.0).seconds
        },
        ip_address: attributes.fetch("ip_address"),
        user_agent: attributes.fetch("user_agent")
      )
    end

    def self.accept(pixel, attributes, lead_ref)
      result = ::Leads::IngestionService.call(pixel: pixel, attributes: ingestion_attributes(attributes, lead_ref))
      return if result.success?

      raise "seed lead #{lead_ref} was refused: #{Array(result.error).to_sentence}"
    end

    def self.ingestion_attributes(attributes, lead_ref)
      {
        public_id: lead_ref,
        session_id: session_id_for(lead_ref),
        page_url: attributes.fetch("landing_page_url"),
        ip_address: attributes.fetch("ip_address"),
        user_agent: attributes.fetch("user_agent"),
        form_dwell_ms: attributes.fetch("form_dwell_ms"),
        submitted_at: captured_at(attributes),
        fields: attributes.slice("first_name", "last_name", "email", "phone", "trusted_form_cert_url")
                          .symbolize_keys
      }
    end

    # Derived against the hint, never from it. If a row disagrees the weights in
    # Seeds::LayerDefinitions are wrong — the engine is not the place to fix it.
    def self.report
      MockData.read("leads.json").fetch("leads").map { |attributes| report_row(attributes) }
    end

    def self.report_row(attributes)
      account = Account.find_by!(public_id: attributes.fetch("account_id"))

      ActsAsTenant.with_tenant(account) do
        lead = Lead.find_by!(public_id: attributes.fetch("lead_id"))
        verdict = lead.verification_run&.consensus_verdict
        # A seed interrupted mid-pipeline leaves a lead whose run never finished,
        # and the next run skips it as already present. Said plainly rather than
        # crashing on a nil three lines later.
        raise "#{lead.public_id} has no verdict — re-run bin/rails db:reset db:seed" if verdict.nil?

        Row.new(lead_ref: lead.public_id, derived: lead.verdict, score: verdict.score,
                via: via(verdict), flags: lead.flags, hint: attributes.fetch("expected_verdict"))
      end
    end

    # The engine's own sentences, verbatim. Re-summarising them here would be a
    # second implementation of the explanation, free to disagree with the one the
    # buyer is shown.
    def self.via(verdict)
      verdict.reasons.join("; ")
    end

    def self.session_id_for(lead_ref)
      "seed-#{lead_ref}"
    end

    def self.captured_at(attributes)
      Time.zone.parse(attributes.fetch("captured_at"))
    end
  end
end
