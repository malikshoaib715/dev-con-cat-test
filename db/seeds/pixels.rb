module Seeds
  # The pixel <-> account binding is taken from the fixtures rather than
  # invented here, so a seeded lead posts through the same pixel it was captured
  # by. localhost is allowed on every seeded pixel so /demo works out of the box.
  module Pixels
    DEMO_DOMAIN = "localhost"

    def self.load!
      pixel_attributes.each do |public_id, attributes|
        account = Account.find_by!(public_id: attributes.fetch(:account_public_id))

        ActsAsTenant.with_tenant(account) do
          pixel = Pixel.find_or_initialize_by(public_id: public_id)
          pixel.update!(
            name: "#{account.name} — #{attributes.fetch(:host)}",
            public_key: deterministic_public_key(public_id),
            allowed_domains: [ attributes.fetch(:host), DEMO_DOMAIN ],
            enabled_layers: enabled_modules.fetch(attributes.fetch(:account_public_id)),
            active: true
          )
        end
      end

      puts "  pixels: #{ActsAsTenant.without_tenant { Pixel.count }}"
    end

    # Derived from the fixture leads: pixel id -> its account and landing page.
    def self.pixel_attributes
      MockData.read("leads.json").fetch("leads").each_with_object({}) do |lead, pixels|
        pixels[lead.fetch("pixel_id")] ||= {
          account_public_id: lead.fetch("account_id"),
          host: URI.parse(lead.fetch("landing_page_url")).host
        }
      end
    end

    def self.enabled_modules
      @enabled_modules ||= MockData.read("accounts.json").fetch("accounts")
                                   .to_h { |account| [ account.fetch("account_id"), account.fetch("enabled_modules") ] }
    end

    # Stable across re-seeds so the snippet pasted into /demo keeps working.
    def self.deterministic_public_key(public_id)
      "pk_#{Digest::SHA256.hexdigest("super-pixel-seed:#{public_id}").first(32)}"
    end
  end
end
