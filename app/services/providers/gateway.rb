# frozen_string_literal: true

module Providers
  # The vendor-call seam. Every processor asks this one object for its layer's
  # payload and never knows whether the answer came from a seeded fixture or a
  # real HTTP call — which is what makes replacing it with actual vendor clients
  # a change to one file.
  #
  # Three tiers, in order:
  #
  #   1. the seeded lead's own recorded response, keyed by lead id;
  #   2. any recorded response for the same *identity* — so typing a fixture
  #      persona's phone number into the live demo replays that persona's whole
  #      scenario end to end, which is a demo feature and not just a fallback;
  #   3. a clean default, so a brand-new lead gets a real verdict instead of ten
  #      errors. An unknown identity is not a suspicious one.
  class Gateway
    # Fixture shapes, with every field the real files carry so a processor sees
    # the same keys whichever tier answered. String keys throughout: the seeded
    # tier comes back from jsonb, and a processor must not have to care.
    CLEAN_DEFAULTS = {
      "vpn_proxy" => {
        "is_vpn" => false, "is_proxy" => false, "is_tor" => false, "is_datacenter" => false,
        "site_visit_ip_matches_submit_ip" => true, "risk" => "low"
      },
      "anura" => {
        "result" => "good", "rule_ids" => [], "invalid_traffic_type" => nil, "confidence" => 0.95
      },
      "trustedform" => {
        "status" => "verified", "matches_phone" => true, "matches_email" => true,
        "consent_language_present" => true, "cert_created_at" => nil, "expires_at" => nil,
        "page_url" => nil
      },
      "blacklist_alliance" => {
        "status" => "clean", "match_score" => 0, "sources" => []
      },
      "dnc" => {
        "dnc_status" => "callable", "national_dnc" => false, "state_dnc" => false,
        "internal_dnc" => false, "callback_window_open" => true, "last_contact_at" => nil
      },
      "phone_validation" => {
        "providers" => {
          "twilio_lookup" => { "valid" => true, "line_type" => "mobile", "carrier" => nil },
          "numverify" => { "valid" => true, "line_type" => "mobile", "carrier" => nil },
          "telesign" => { "valid" => true, "line_type" => "mobile", "carrier" => nil }
        }
      },
      "email_validation" => {
        "providers" => {
          "zerobounce" => { "deliverable" => true, "disposable" => false, "fraud_score" => 5 },
          "neverbounce" => { "deliverable" => true, "disposable" => false, "fraud_score" => 5 }
        }
      },
      "enrichment" => {
        "audiencelabs" => {
          "matched" => true, "address" => nil, "age_band" => nil,
          "household_income" => nil, "match_to_lead" => true
        },
        "bytemine" => {
          "matched" => true, "address" => nil, "age_band" => nil, "match_to_lead" => true
        }
      },
      # A lead that arrived through a web form has no voice sample, which is
      # not_applicable rather than a pass.
      "voice" => { "has_sample" => false, "verdict" => nil }
    }.freeze

    # Fixed per layer rather than random, so the panel trickles the same way every
    # time a scenario is demonstrated. Roughly what each vendor really costs in
    # wall time: a cache lookup is quick, a voice model is not.
    LATENCY_MS = {
      "vpn_proxy" => 250, "anura" => 420, "trustedform" => 380, "blacklist_alliance" => 340,
      "dnc" => 300, "phone_validation" => 620, "email_validation" => 480,
      "enrichment" => 760, "voice" => 900
    }.freeze

    def self.fetch(layer_key:, lead:)
      new(layer_key: layer_key, lead: lead).fetch
    end

    def initialize(layer_key:, lead:)
      @layer_key = layer_key
      @lead = lead
    end

    def fetch
      require_a_vendor_backed_layer
      simulate_latency

      recorded_for_this_lead&.payload || recorded_for_this_identity&.payload || clean_default
    end

    private

    # duplicate_detection has no vendor: it is answered from the buyer's own CRM.
    # Asking here is a programmer error, not a cache miss.
    def require_a_vendor_backed_layer
      return if CLEAN_DEFAULTS.key?(@layer_key)

      raise ArgumentError, "no provider for layer: #{@layer_key.inspect}"
    end

    def recorded_for_this_lead
      ProviderResponse.find_by(layer_key: @layer_key, lead_ref: @lead.public_id)
    end

    # Phone before email: it is the more identifying of the two for a product
    # whose whole job is deciding whether a number may be dialled. Ordered so a
    # persona whose identity appears on several fixtures always replays the same
    # one.
    def recorded_for_this_identity
      match_on(:phone_normalized, @lead.phone_normalized) || match_on(:email_normalized, @lead.email_normalized)
    end

    def match_on(column, value)
      return nil if value.blank?

      ProviderResponse.for_layer(@layer_key).where(column => value).order(:lead_ref).first
    end

    def clean_default
      CLEAN_DEFAULTS.fetch(@layer_key).deep_dup
    end

    # Off everywhere but development: the suite would spend its life asleep and
    # seeding twelve leads would take a minute for no gain.
    def simulate_latency
      return unless Rails.application.config.x.providers.simulated_latency

      sleep(LATENCY_MS.fetch(@layer_key) / 1000.0)
    end
  end
end
