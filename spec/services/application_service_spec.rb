require "rails_helper"

RSpec.describe ApplicationService do
  # One Result type for the whole app: expected domain outcomes are values,
  # bugs are exceptions.
  let(:service_class) do
    Class.new(described_class) do
      def initialize(outcome)
        @outcome = outcome
      end

      def call
        case @outcome
        when :ok      then success(:done)
        when :refused then failure("not enough credits", code: "insufficient_credits")
        else raise NoMethodError, "a real bug"
        end
      end
    end
  end

  it "wraps an expected success" do
    result = service_class.call(:ok)

    expect(result).to be_success
    expect(result).not_to be_failure
    expect(result.value).to eq(:done)
  end

  it "wraps an expected domain failure as a value, with a machine-readable code" do
    result = service_class.call(:refused)

    expect(result).to be_failure
    expect(result.error).to eq([ "not enough credits" ])
    expect(result.code).to eq("insufficient_credits")
  end

  it "lets a genuine bug escape to the boundary instead of hiding it in a Result" do
    expect { service_class.call(:boom) }.to raise_error(NoMethodError, "a real bug")
  end
end
