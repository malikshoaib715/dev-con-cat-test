# frozen_string_literal: true

module Certificates
  # One byte sequence per document, whatever order the keys arrived in.
  #
  # This exists to kill a specific bug. Postgres `jsonb` does not preserve key
  # order, so hashing `evidence.to_json` at issuance and re-hashing the same
  # evidence after a database round trip produces two different digests — every
  # certificate would verify as tampered the moment it was reloaded. Sorting the
  # keys before generating makes the digest a property of the content rather than
  # of how it was written.
  #
  # Array order is meaningful and is left exactly as it is.
  module CanonicalJson
    def self.generate(object)
      JSON.generate(sort(object))
    end

    # Both issuance and verification digest through here, so there is exactly one
    # definition of a document's hash and no way for the two sides to drift.
    def self.hexdigest(object)
      Digest::SHA256.hexdigest(generate(object))
    end

    def self.sort(object)
      case object
      when Hash  then object.keys.sort.each_with_object({}) { |key, sorted| sorted[key] = sort(object[key]) }
      when Array then object.map { |element| sort(element) }
      else object
      end
    end
  end
end
