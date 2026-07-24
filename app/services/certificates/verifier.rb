# frozen_string_literal: true

module Certificates
  # Recomputes a certificate's hash from the evidence it stores, and checks that it
  # still sits where it claims to in its account's chain.
  #
  # Tampering is a result, not an exception: the public verifier's whole job is to
  # render it, so this returns a report rather than raising.
  class Verifier
    Report = Data.define(:hash_valid, :chain_valid, :expected_hash) do
      def valid?
        hash_valid && chain_valid
      end

      def status
        valid? ? "VALID" : "TAMPERED"
      end
    end

    def self.call(certificate:)
      new(certificate: certificate).call
    end

    def initialize(certificate:)
      @certificate = certificate
    end

    def call
      Report.new(hash_valid: hash_valid?, chain_valid: chain_valid?, expected_hash: expected_hash)
    end

    private

    def expected_hash
      @expected_hash ||= CanonicalJson.hexdigest(@certificate.evidence)
    end

    def hash_valid?
      ActiveSupport::SecurityUtils.secure_compare(expected_hash, @certificate.evidence_hash.to_s)
    end

    # The link, not just the digest: a certificate whose own evidence is intact can
    # still be sitting on top of a predecessor that was edited, and this is what
    # notices.
    def chain_valid?
      return @certificate.previous_hash.nil? if first_in_chain?
      return false if predecessor.nil?

      @certificate.previous_hash == predecessor.evidence_hash
    end

    def first_in_chain?
      @certificate.sequence_number == 1
    end

    def predecessor
      return @predecessor if defined?(@predecessor)

      @predecessor = ActsAsTenant.with_tenant(@certificate.account) do
        ConsentCertificate.find_by(account_id: @certificate.account_id,
                                   sequence_number: @certificate.sequence_number - 1)
      end
    end
  end
end
