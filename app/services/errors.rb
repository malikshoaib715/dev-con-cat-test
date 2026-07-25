# frozen_string_literal: true

# Expected domain failures. Anything not listed here is a bug and is allowed to
# reach the boundary that knows what to do with it (a 500 with a request id, or
# a Sidekiq retry) rather than being swallowed into a generic message.
module Errors
  class DomainError < StandardError
    # Machine-readable code carried into the JSON envelope.
    def code
      self.class.name.demodulize.underscore
    end
  end

  # A replayed submission is deliberately absent: it is a success outcome (the
  # original lead is returned, idempotently), not an error.
  class ValidationFailed    < DomainError; end
  class PixelNotAuthorized  < DomainError; end
  class OriginNotAllowed    < DomainError; end
  class InsufficientCredits < DomainError; end
  class InvalidTransition   < DomainError; end
  class CertificateTampered < DomainError; end

  # Retryable: the vendor might answer next time.
  class ProviderUnavailable < DomainError; end
end
