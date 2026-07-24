module Seeds
  # The buyers' own existing customers, which duplicate detection matches against.
  # Grouped by account in the fixture and kept that way here: the same person in
  # two buyers' CRMs is two legitimate leads, not a duplicate.
  module CrmRecords
    def self.load!
      MockData.read("buyers_crm.json").fetch("crm_records").each do |account_public_id, records|
        account = Account.find_by!(public_id: account_public_id)

        ActsAsTenant.with_tenant(account) do
          records.each { |attributes| upsert(account, attributes) }
        end
      end

      puts "  crm_records: #{ActsAsTenant.without_tenant { CrmRecord.count }}"
    end

    def self.upsert(account, attributes)
      record = CrmRecord.find_or_initialize_by(account: account, external_ref: attributes.fetch("crm_id"))
      email = attributes["email"]
      phone = attributes["phone"]

      record.update!(
        first_name: attributes["first_name"],
        last_name: attributes["last_name"],
        email: email,
        # Normalized through the same functions ingestion uses, or a duplicate
        # would only be caught when the visitor happened to type their number the
        # same way the CRM export did.
        email_normalized: ::Leads::Normalizer.email(email),
        phone: phone,
        phone_normalized: ::Leads::Normalizer.phone(phone),
        source_created_at: attributes.fetch("created_at")
      )
    end
  end
end
