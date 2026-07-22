# Test scaffolding: ActiveJob serialises jobs by class name, so the retry policy
# in ApplicationJob has to be exercised through a real constant rather than an
# anonymous class.
class SpecProbeJob < ApplicationJob
  cattr_accessor :attempts, default: 0
  cattr_accessor :failure

  def perform
    self.class.attempts += 1
    self.class.failure&.call
  end
end
