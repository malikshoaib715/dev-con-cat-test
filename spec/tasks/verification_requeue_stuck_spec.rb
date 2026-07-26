require "rails_helper"
require "rake"

# The operational recovery path (§7.4): after Redis has been down, one task
# resumes every run the outage stranded, across every tenant, without a
# dashboard click per lead.
RSpec.describe "verification:requeue_stuck", type: :task do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("verification:requeue_stuck") }
  before { Rake::Task["verification:requeue_stuck"].reenable }

  def invoke
    capture_stdout { Rake::Task["verification:requeue_stuck"].invoke }
  end

  def stranded_run(account)
    as_tenant(account) do
      run = create(:verification_run, account: account, status: "pending",
                                      created_at: 10.minutes.ago, updated_at: 10.minutes.ago)
      create(:layer_result, account: account, verification_run: run, layer_key: "anura", status: "pending")
      run
    end
  end

  it "resumes stuck runs across every tenant" do
    run_a = stranded_run(create(:account))
    run_b = stranded_run(create(:account))

    expect { invoke }.to change { enqueued_jobs.size }.by(2)

    expect(enqueued_jobs.map { |job| job[:args].first }).to contain_exactly(run_a.id, run_b.id)
  end

  it "leaves a run somebody is actively working on alone" do
    account = create(:account)
    live_run = as_tenant(account) do
      create(:verification_run, account: account, status: "running",
                                created_at: 10.minutes.ago, updated_at: 10.minutes.ago).tap do |run|
        create(:layer_result, account: account, verification_run: run, layer_key: "anura",
                              status: "processing", started_at: 10.seconds.ago)
      end
    end

    output = invoke

    expect(enqueued_jobs).to be_empty
    expect(output).to include("nothing is stuck")
    expect(live_run.reload.status).to eq("running")
  end

  it "says what it resumed, so an operator can read the run it just saved" do
    run = stranded_run(create(:account))

    expect(invoke).to include(run.lead.public_id)
  end
end
