# frozen_string_literal: true

module Layers
  # The one place layer keys are spelled. These strings are simultaneously the
  # fixture filenames, the account `enabled_modules` values, the credit-cost
  # keys, and the landing page's panel labels — an alias anywhere else
  # (`trusted_form`, `voice_ai`, `duplicate`) is a bug, not a synonym.
  module Registry
    Entry = Data.define(:key, :label, :position, :processor_name) do
      def processor
        processor_name.constantize
      end
    end

    ENTRIES = [
      Entry.new(key: "vpn_proxy",           label: "VPN / Proxy",      position: 1,  processor_name: "Layers::VpnProxyProcessor"),
      Entry.new(key: "anura",               label: "Anura",            position: 2,  processor_name: "Layers::AnuraProcessor"),
      Entry.new(key: "trustedform",         label: "TrustedForm",      position: 3,  processor_name: "Layers::TrustedformProcessor"),
      Entry.new(key: "blacklist_alliance",  label: "Litigator",        position: 4,  processor_name: "Layers::BlacklistAllianceProcessor"),
      Entry.new(key: "dnc",                 label: "DNC / Callback",   position: 5,  processor_name: "Layers::DncProcessor"),
      Entry.new(key: "phone_validation",    label: "Phone consensus",  position: 6,  processor_name: "Layers::PhoneValidationProcessor"),
      Entry.new(key: "email_validation",    label: "Email consensus",  position: 7,  processor_name: "Layers::EmailValidationProcessor"),
      Entry.new(key: "enrichment",          label: "Enrichment",       position: 8,  processor_name: "Layers::EnrichmentProcessor"),
      Entry.new(key: "duplicate_detection", label: "Duplicate",        position: 9,  processor_name: "Layers::DuplicateDetectionProcessor"),
      Entry.new(key: "voice",               label: "Voice AI",         position: 10, processor_name: "Layers::VoiceProcessor")
    ].freeze

    BY_KEY = ENTRIES.index_by(&:key).freeze

    class << self
      def keys
        BY_KEY.keys
      end

      def entries
        ENTRIES
      end

      def fetch(key)
        BY_KEY.fetch(key) { raise ArgumentError, "unknown layer key: #{key.inspect}" }
      end

      def key?(key)
        BY_KEY.key?(key)
      end

      def label(key)
        fetch(key).label
      end

      def processor_for(key)
        fetch(key).processor
      end
    end
  end
end
