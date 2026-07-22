module Seeds
  module Users
    # The fixture passwords are placeholders and are only ever used to create a
    # seeded account; an existing user's password is never rewritten by a
    # re-seed.
    def self.load!
      MockData.read("users.json").fetch("users").each do |attributes|
        user = User.find_or_initialize_by(email: attributes.fetch("email"))
        user.name = attributes.fetch("name")
        user.role = attributes.fetch("role")
        user.account = account_for(attributes["account_id"])
        user.password = attributes.fetch("placeholder_password") if user.new_record?
        user.save!
      end

      puts "  users: #{User.count}"
    end

    def self.account_for(public_id)
      return nil if public_id.blank?

      Account.find_by!(public_id: public_id)
    end

    def self.credentials_table
      MockData.read("users.json").fetch("users").map do |attributes|
        [ attributes.fetch("email"), attributes.fetch("placeholder_password"), attributes.fetch("role") ]
      end
    end
  end
end
