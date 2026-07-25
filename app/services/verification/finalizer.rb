# frozen_string_literal: true

module Verification
  # Turns a finished run into everything it owes the buyer: a verdict, a
  # certificate, a settled bill, and a lead they can act on.
  #
  # Order is deliberate — verdict, then certificate, then settlement, then the run
  # is closed. A crash between any two steps leaves a run still marked
  # `finalizing`, which is recoverable, and every step skips work that already
  # exists: unique indexes on the verdict, the certificate and the ledger entry
  # type are the backstops that make a redelivered job harmless rather than a
  # double charge.
  #
  # Reached only through Verification::CompletionGate, which is what guarantees a
  # single caller: this service assumes the claim has already been won.
  class Finalizer < ApplicationService
    def initialize(run:)
      @run = run
    end

    def call
      return success(@run.consensus_verdict) if @run.completed?
      raise Errors::InvalidTransition, "run #{@run.id} is #{@run.status}, not finalizing" unless @run.finalizing?

      verdict = record_decision(Consensus::Engine.call(run: @run, policy: policy))
      Certificates::Issuer.call(run: @run, consensus_verdict: verdict)
      Credits::Settlement.call(run: @run)
      @run.update!(status: "completed", completed_at: Time.current)

      success(verdict)
    end

    private

    # Everything the decision implies, or none of it: a lead marked accepted whose
    # verdict row never committed would be a lead the buyer acts on and cannot
    # explain.
    def record_decision(decision)
      ApplicationRecord.transaction do
        verdict = persist_verdict(decision)
        backfill_layer_deltas(decision)
        # Before the audits, deliberately: `verdict.issued` is what tells the CRM
        # to redraw this lead's row, and a row redrawn from a lead that does not
        # yet carry its own verdict would show the reader the previous state.
        denormalize_lead(decision)
        record_audits(decision)
        append_to_crm(decision)
        verdict
      end
    end

    # In its own savepoint so that losing the race does not abort the enclosing
    # transaction — Postgres refuses further work after a failed statement, so
    # rescuing without one would take the whole finalization down with it. The
    # verdict that already exists wins: it is the one the certificate may already
    # have been issued against.
    def persist_verdict(decision)
      ApplicationRecord.transaction(requires_new: true) do
        @run.create_consensus_verdict!(
          account: @run.account,
          verdict: decision.verdict,
          score: decision.score,
          reasons: decision.reasons,
          flags: decision.flags,
          hard_stop_layer: decision.hard_stop_layer,
          policy_snapshot: decision.policy_snapshot,
          issued_at: Time.current
        )
      end
    rescue ActiveRecord::RecordNotUnique
      @run.reload.consensus_verdict
    end

    # `update_columns` deliberately skips callbacks and validations: this writes one
    # derived number onto rows that are already terminal, and running validations
    # over ten finished layer results would only re-litigate what the pipeline has
    # already recorded.
    def backfill_layer_deltas(decision)
      rows = @run.layer_results.index_by(&:layer_key)

      decision.per_layer_deltas.each do |layer_key, delta|
        rows[layer_key]&.update_columns(score_delta: delta)
      end
    end

    def record_audits(decision)
      Audit::Recorder.record!(
        Audit::Events::CONSENSUS_EVALUATED,
        subject: lead,
        payload: { score: decision.score, deltas: decision.per_layer_deltas,
                   hard_stop_layer: decision.hard_stop_layer }
      )
      # The event the live panel renders as its final frame. Everything the page
      # needs is in the payload, so realtime stays a reading of the audit spine.
      Audit::Recorder.record!(
        Audit::Events::VERDICT_ISSUED,
        subject: lead,
        payload: { verdict: decision.verdict, score: decision.score,
                   reasons: decision.reasons, flags: decision.flags }
      )
    end

    def denormalize_lead(decision)
      lead.update!(status: "completed", verdict: decision.verdict, flags: decision.flags)
    end

    # Only accepted leads enter the buyer's CRM — which is what makes tomorrow's
    # resubmission of the same person a detectable duplicate. A rejected lead was
    # never bought, so recording it would invent a customer relationship that does
    # not exist and reject a second, better submission from the same person.
    def append_to_crm(decision)
      return unless decision.verdict == "accept"

      CrmRecord.find_or_create_by!(external_ref: lead.public_id) do |record|
        record.account = @run.account
        record.first_name = lead.first_name
        record.last_name = lead.last_name
        record.email = lead.email
        record.email_normalized = lead.email_normalized
        record.phone = lead.phone
        record.phone_normalized = lead.phone_normalized
        record.source_created_at = lead.submitted_at
      end
    end

    def policy
      Consensus::Policy.for(account: @run.account)
    end

    def lead
      @lead ||= @run.lead
    end
  end
end
