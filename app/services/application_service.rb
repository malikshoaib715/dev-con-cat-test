# frozen_string_literal: true

# One base, one Result type. Services return failures for *expected* domain
# outcomes (insufficient credits, replay, validation) and deliberately do not
# rescue StandardError: swallowing a NoMethodError into "unexpected error"
# hides bugs and breaks job retry semantics.
class ApplicationService
  Result = Struct.new(:ok, :value, :error, :code, keyword_init: true) do
    def success?
      ok
    end

    def failure?
      !ok
    end
  end

  def self.call(...)
    new(...).call
  end

  private

  def success(value = nil)
    Result.new(ok: true, value: value, error: [], code: nil)
  end

  def failure(error, code: nil)
    Result.new(ok: false, value: nil, error: Array(error), code: code)
  end
end
