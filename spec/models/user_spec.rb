require "rails_helper"

RSpec.describe User do
  it "requires an account for a tenant user" do
    user = build(:user, account: nil, role: "member")

    expect(user).not_to be_valid
    expect(user.errors[:account]).to be_present
  end

  it "refuses an account for a platform operator" do
    user = build(:user, :super_admin, account: create(:account))

    expect(user).not_to be_valid
    expect(user.errors[:account]).to be_present
  end

  it "enforces the role/account pairing in the database as well" do
    user = create(:user, :super_admin)
    account = create(:account)

    expect { user.update_column(:account_id, account.id) }
      .to raise_error(ActiveRecord::StatementInvalid, /users_account_matches_role/)
  end

  it "authenticates with the password it was created with" do
    user = create(:user, password: "Sup3rPixel!pw")

    expect(user.valid_password?("Sup3rPixel!pw")).to be(true)
    expect(user.valid_password?("wrong")).to be(false)
  end

  it "does not offer self-service registration" do
    expect(User.devise_modules).not_to include(:registerable)
    expect(User.devise_modules).to include(:database_authenticatable, :rememberable, :validatable)
  end
end
