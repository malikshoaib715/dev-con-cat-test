# frozen_string_literal: true

namespace :verification do
  desc "Resume verification runs nothing is working on any more"
  task requeue_stuck: :environment do
    stuck_runs = ActsAsTenant.without_tenant { VerificationRun.stuck.includes(:account, :lead).to_a }

    if stuck_runs.empty?
      puts "verification:requeue_stuck OK — nothing is stuck"
      next
    end

    stuck_runs.each do |run|
      ActsAsTenant.with_tenant(run.account) do
        result = Verification::Resumer.call(run: run)
        outcome = result.success? ? "resumed (#{run.reload.status})" : "FAILED: #{result.error.to_sentence}"
        puts format("  %-16s run %-6d %s", run.lead.public_id, run.id, outcome)
      end
    end
  end
end
