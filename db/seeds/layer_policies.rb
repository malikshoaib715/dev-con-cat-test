module Seeds
  # `enabled_modules` in the fixtures is what an account pays for. Every account
  # gets a row for every layer — an explicitly disabled layer is how the
  # not_enabled state stays distinguishable from "we forgot to check".
  module LayerPolicies
    def self.load!
      MockData.read("accounts.json").fetch("accounts").each do |attributes|
        account = Account.find_by!(public_id: attributes.fetch("account_id"))
        purchased = attributes.fetch("enabled_modules")

        ActsAsTenant.with_tenant(account) do
          Layers::Registry.keys.each do |layer_key|
            policy = LayerPolicy.find_or_initialize_by(account: account, layer_key: layer_key)
            policy.update!(enabled: purchased.include?(layer_key))
          end
        end
      end

      puts "  layer_policies: #{ActsAsTenant.without_tenant { LayerPolicy.count }}"
    end
  end
end
