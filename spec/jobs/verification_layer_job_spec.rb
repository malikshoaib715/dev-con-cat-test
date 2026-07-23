require "rails_helper"

RSpec.describe VerificationLayerJob do
  # A factory account has no seeded provider responses, so the gateway answers with
  # clean defaults — which is exactly what an unknown lead does in production.
  def build_run(layer_keys, run_status: "running")
    account = create(:account)
    as_tenant(account) do
      lead = create(:lead, account: account, session_id: "sess_pipeline")
      run = create(:verification_run, account: account, lead: lead, status: run_status)
      layer_keys.each do |layer_key|
        create(:layer_result, account: account, verification_run: run, layer_key: layer_key, status: "pending")
      end
      run
    end
  end

  def layer_result(run, layer_key)
    as_tenant(run.account) { run.layer_results.find_by!(layer_key: layer_key) }
  end

  def events_of_type(event_type)
    ActsAsTenant.without_tenant { AuditEvent.of_type(event_type) }
  end

  # Draining is a single pass, and each attempt enqueues the next one with a
  # back-off, so the queue has to be drained repeatedly and past the wait.
  # Bounded by the retry count so a job that somehow never settles fails the
  # example rather than looping forever.
  DRAIN_PASSES = 5

  def perform_with_retries(run)
    described_class.perform_later(run.id, "anura")

    DRAIN_PASSES.times do
      break if enqueued_jobs.empty?

      perform_enqueued_jobs(at: 1.day.from_now)
    end
  end

  before { load_layer_definitions }

  it "runs on the layers queue, so a burst of layer work cannot starve finalization" do
    expect(described_class.new.queue_name).to eq("layers")
  end

  describe "a layer that reports a verdict" do
    let(:run) { build_run(%w[anura]) }

    before { described_class.perform_now(run.id, "anura") }

    it "persists the processor's outcome" do
      row = layer_result(run, "anura")

      expect(row.status).to eq("completed")
      expect(row.verdict).to eq("good")
      expect(row.panel_verdict).to eq("pass")
      expect(row.detail).to eq("result: good")
      expect(row.started_at).to be_present
      expect(row.completed_at).to be_present
    end

    it "keeps the vendor's answer and the weighted signals together" do
      expect(layer_result(run, "anura").raw_response).to include("result" => "good", "signals" => [])
    end

    it "records the layer starting and finishing, correlated to the pixel session" do
      expect(events_of_type(Audit::Events::LAYER_STARTED).sole.session_id).to eq("sess_pipeline")

      completed = events_of_type(Audit::Events::LAYER_COMPLETED).sole
      expect(completed.subject_id).to eq(run.lead_id)
      expect(completed.session_id).to eq("sess_pipeline")
      expect(completed.payload).to include("layer_key" => "anura", "panel_verdict" => "pass")
    end

    it "attributes the work to the platform, since no human asked for it" do
      expect(events_of_type(Audit::Events::LAYER_COMPLETED).sole.actor_type).to eq("system")
    end
  end

  describe "a layer that does not apply" do
    let(:run) { build_run(%w[voice]) }

    before { described_class.perform_now(run.id, "voice") }

    it "records it as skipped rather than passed" do
      row = layer_result(run, "voice")

      expect(row.status).to eq("not_applicable")
      expect(row.panel_verdict).to eq("skip")
      expect(row.verdict).to be_nil
    end

    it "puts a skip on the timeline, not a completion" do
      expect(events_of_type(Audit::Events::LAYER_SKIPPED).count).to eq(1)
      expect(events_of_type(Audit::Events::LAYER_COMPLETED)).to be_empty
    end
  end

  # Sidekiq delivers at least once, so this is normal traffic rather than an edge
  # case.
  describe "delivered twice" do
    let(:run) { build_run(%w[anura]) }

    before do
      described_class.perform_now(run.id, "anura")
      described_class.perform_now(run.id, "anura")
    end

    it "leaves one completed row" do
      expect(layer_result(run, "anura").status).to eq("completed")
      expect(as_tenant(run.account) { run.layer_results.count }).to eq(1)
    end

    it "does not put the layer on the timeline twice" do
      expect(events_of_type(Audit::Events::LAYER_STARTED).count).to eq(1)
      expect(events_of_type(Audit::Events::LAYER_COMPLETED).count).to eq(1)
    end
  end

  it "leaves a layer the account never bought alone" do
    run = build_run([])
    as_tenant(run.account) do
      create(:layer_result, account: run.account, verification_run: run, layer_key: "voice",
                            status: "not_enabled", panel_verdict: "skip")
    end

    described_class.perform_now(run.id, "voice")

    expect(layer_result(run, "voice").status).to eq("not_enabled")
    expect(events_of_type(Audit::Events::LAYER_STARTED)).to be_empty
  end

  describe "finalization" do
    it "does not claim the run while other layers are outstanding" do
      run = build_run(%w[anura dnc])

      described_class.perform_now(run.id, "anura")

      expect(run.reload.status).to eq("running")
    end

    it "claims the run once the last layer has reported" do
      run = build_run(%w[anura dnc])

      described_class.perform_now(run.id, "anura")
      described_class.perform_now(run.id, "dnc")

      expect(run.reload.status).to eq("finalizing")
    end
  end

  describe "a layer whose provider is unavailable" do
    let(:run) { build_run(%w[anura dnc]) }

    before do
      allow(Layers::AnuraProcessor).to receive(:call).and_raise(Errors::ProviderUnavailable, "vendor down")
      described_class.perform_now(run.id, "dnc")
    end

    it "retries before giving up on it" do
      perform_with_retries(run)

      expect(Layers::AnuraProcessor).to have_received(:call).exactly(4).times
    end

    # Without this the first transient failure would leave the row claimed, every
    # retry would decline to claim it and quietly succeed, and the run would sit in
    # `running` forever having done nothing.
    it "hands the claim back between attempts so a retry can pick the layer up" do
      described_class.perform_later(run.id, "anura")
      perform_enqueued_jobs(at: 1.day.from_now)

      row = layer_result(run, "anura")
      expect(row.status).to eq("pending")
      expect(row.started_at).to be_nil
    end

    # A dead vendor must never leave the run stuck in `running` forever.
    it "records the layer as errored and lets the run move on" do
      perform_with_retries(run)

      row = layer_result(run, "anura")
      expect(row.status).to eq("errored")
      expect(row.error_class).to eq("Errors::ProviderUnavailable")
      expect(row.error_message).to eq("vendor down")
      expect(run.reload.status).to eq("finalizing")
    end

    # Never presented as a pass: the certificate has to be able to tell an
    # unavailable check from a cleared one.
    it "shows the panel a warning rather than a pass or a failure" do
      perform_with_retries(run)

      expect(layer_result(run, "anura").panel_verdict).to eq("warn")
      expect(layer_result(run, "anura").detail).to eq("layer unavailable")
    end

    it "records why on the timeline" do
      perform_with_retries(run)

      expect(events_of_type(Audit::Events::LAYER_ERRORED).sole.payload)
        .to include("layer_key" => "anura", "error_class" => "Errors::ProviderUnavailable")
    end
  end

  describe "a layer that hits an outright bug" do
    let(:run) { build_run(%w[anura dnc]) }

    before do
      allow(Layers::AnuraProcessor).to receive(:call).and_raise(NoMethodError, "undefined method 'result'")
      described_class.perform_now(run.id, "dnc")
    end

    # Bookkeeping first so the run is never stranded, then re-raised so the bug
    # stays visible in Sidekiq rather than being quietly absorbed.
    it "records the failure and still lets the bug surface" do
      expect { described_class.perform_now(run.id, "anura") }.to raise_error(NoMethodError)

      expect(layer_result(run, "anura").status).to eq("errored")
      expect(layer_result(run, "anura").error_class).to eq("NoMethodError")
      expect(run.reload.status).to eq("finalizing")
    end

    it "no-ops when the retried job finds the row already terminal" do
      expect { described_class.perform_now(run.id, "anura") }.to raise_error(NoMethodError)

      described_class.perform_now(run.id, "anura")

      expect(events_of_type(Audit::Events::LAYER_ERRORED).count).to eq(1)
    end
  end

  describe "a claim abandoned by a dead worker" do
    let(:run) { build_run(%w[anura]) }

    # Without this the row would sit in `processing` forever and the run would
    # never finalize.
    it "may be taken again once it has gone stale" do
      as_tenant(run.account) do
        run.layer_results.find_by!(layer_key: "anura")
           .update!(status: "processing", started_at: 10.minutes.ago)
      end

      described_class.perform_now(run.id, "anura")

      expect(layer_result(run, "anura").status).to eq("completed")
    end

    it "is left alone while it is still fresh" do
      as_tenant(run.account) do
        run.layer_results.find_by!(layer_key: "anura")
           .update!(status: "processing", started_at: 30.seconds.ago)
      end

      described_class.perform_now(run.id, "anura")

      expect(layer_result(run, "anura").status).to eq("processing")
    end
  end

  describe "two workers handed the same layer", :real_transactions do
    it "lets exactly one of them process it" do
      load_layer_definitions
      run = build_run(%w[anura])

      in_parallel(4, tenant: run.account) { described_class.perform_now(run.id, "anura") }

      expect(layer_result(run, "anura").status).to eq("completed")
      expect(events_of_type(Audit::Events::LAYER_STARTED).count).to eq(1)
      expect(events_of_type(Audit::Events::LAYER_COMPLETED).count).to eq(1)
    end
  end

  describe "tenancy" do
    it "opens the run's own tenant, since a worker starts with none" do
      run = build_run(%w[anura])

      described_class.perform_now(run.id, "anura")

      expect(layer_result(run, "anura").account_id).to eq(run.account_id)
      expect(events_of_type(Audit::Events::LAYER_COMPLETED).sole.account_id).to eq(run.account_id)
    end
  end
end
