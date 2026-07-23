require "rails_helper"
require_relative "../../../db/seeds/mock_data"

RSpec.describe Leads::Normalizer do
  describe ".phone" do
    it "lands every shape a visitor might type on the one the fixtures use" do
      [
        "+13105550142",
        "13105550142",
        "3105550142",
        "(310) 555-0142",
        "310-555-0142",
        "+1 310 555 0142",
        " 310.555.0142 "
      ].each do |typed|
        expect(described_class.phone(typed)).to eq("+13105550142")
      end
    end

    it "leaves an international number its own country code" do
      expect(described_class.phone("+44 20 7123 4567")).to eq("+442071234567")
    end

    it "has nothing to normalize when there is no number" do
      expect(described_class.phone(nil)).to be_nil
      expect(described_class.phone("")).to be_nil
      expect(described_class.phone("   ")).to be_nil
      expect(described_class.phone("not a phone")).to be_nil
    end

    # Normalized values are stored, indexed, and compared against later
    # normalizations, so running the function over its own output has to be a
    # no-op or matching silently rots.
    it "is idempotent" do
      [ "(310) 555-0142", "+44 20 7123 4567", "555-0142" ].each do |typed|
        once = described_class.phone(typed)
        expect(described_class.phone(once)).to eq(once)
      end
    end

    it "already agrees with every number the fixtures ship" do
      fixture_phones.each do |phone|
        expect(described_class.phone(phone)).to eq(phone)
      end
    end
  end

  describe ".email" do
    it "folds case and trims, so the same mailbox typed twice matches" do
      expect(described_class.email("  Maria.Gonzalez@GMAIL.com ")).to eq("maria.gonzalez@gmail.com")
    end

    it "has nothing to normalize when there is no address" do
      expect(described_class.email(nil)).to be_nil
      expect(described_class.email("")).to be_nil
      expect(described_class.email("  ")).to be_nil
    end

    it "is idempotent" do
      once = described_class.email(" Maria.Gonzalez@GMAIL.com ")
      expect(described_class.email(once)).to eq(once)
    end

    # L-1008's domain carries a Cyrillic "о" where the Latin one belongs. Folding
    # it into ASCII would turn an address whose domain does not resolve into one
    # that does, and the lead's whole scenario would disappear. Detecting the
    # lookalike is the email provider's job; ours is to compare exactly.
    describe "a homoglyph domain" do
      # о is CYRILLIC SMALL LETTER O, spelled as an escape so the difference
      # from the line below is visible rather than a trap for the next reader.
      let(:homoglyph_email) { "grace.adeyemi@n\u043E-such-domain.example" }
      let(:ascii_lookalike) { "grace.adeyemi@no-such-domain.example" }

      it "survives normalization byte for byte" do
        expect(described_class.email(homoglyph_email)).to eq(homoglyph_email)
      end

      it "never becomes its ASCII lookalike" do
        expect(described_class.email(homoglyph_email)).not_to eq(described_class.email(ascii_lookalike))
      end

      it "is the address the fixture actually ships" do
        expect(fixture_emails).to include(homoglyph_email)
      end
    end

    it "already agrees with every address the fixtures ship" do
      fixture_emails.each do |email|
        expect(described_class.email(email)).to eq(email)
      end
    end
  end

  def fixture_leads
    @fixture_leads ||= Seeds::MockData.read("leads.json").fetch("leads")
  end

  def fixture_crm_records
    @fixture_crm_records ||= Seeds::MockData.read("buyers_crm.json").fetch("crm_records").values.flatten
  end

  def fixture_phones
    (fixture_leads + fixture_crm_records).map { |record| record.fetch("phone") }
  end

  def fixture_emails
    (fixture_leads + fixture_crm_records).map { |record| record.fetch("email") }
  end
end
