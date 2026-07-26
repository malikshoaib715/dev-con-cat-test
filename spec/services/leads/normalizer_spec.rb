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

  # Reachability, as distinct from identity. `.phone` and `.email` answer "are
  # these two records the same person"; these two answer "could anyone contact
  # this one at all" — the question the vendor fixtures never ask, because every
  # one of them answers about an identity rather than refusing an unusable one.
  describe ".dialable?" do
    it "accepts the shapes the fixtures and a visitor's keyboard produce" do
      [ "+13105550142", "3105550142", "(310) 555-0142", "+44 20 7123 4567", "03096619196" ]
        .each { |typed| expect(described_class.dialable?(typed)).to be(true), "expected #{typed}" }
    end

    it "refuses what could not be a whole number, however filled-in it looks" do
      # "999+1234" is seven digits in a field somebody did type into. A national
      # number is ten (NANP) and E.164 stops at fifteen.
      [ nil, "", ",dc kwc qkcjn q", "abc1", "12345", "999+1234", "1234567890123456" ]
        .each { |typed| expect(described_class.dialable?(typed)).to be(false), "expected #{typed}" }
    end

    # The honest limit of a shape check, stated as a test so nobody mistakes this
    # for validation. Fifteen digits is a legal E.164 length, so "+930976543234567"
    # is *possible* — it is only unassigned, which no count of digits can know.
    # Whether a possible number is a real one is the phone-consensus layer's
    # question, and it is the vendors who answer it.
    it "cannot tell a possible number from an assigned one — that is the layer's job" do
      expect(described_class.dialable?("9+30976543234567")).to be(true)
    end

    it "agrees with every phone the fixtures carry" do
      fixture_phones.each { |phone| expect(described_class.dialable?(phone)).to be(true), phone }
    end
  end

  describe ".deliverable_shape?" do
    it "accepts an address mail could be attempted to" do
      [ "maria.gonzalez@gmail.com", "a+tag@sub.example.co.uk", " Name@Example.COM " ]
        .each { |typed| expect(described_class.deliverable_shape?(typed)).to be(true), "expected #{typed}" }
    end

    # Each of these is accepted by `type="email"` and by RFC 5322: a dotless host
    # is legal mail on a local network. A lead's address is not local.
    it "refuses an address with nowhere to deliver to" do
      [ nil, "", "fghjk@njjj", "fgh@hg", "nobody", "@example.com", "two@@dots.com" ]
        .each { |typed| expect(described_class.deliverable_shape?(typed)).to be(false), "expected #{typed}" }
    end

    it "agrees with every address the fixtures carry" do
      fixture_emails.each { |email| expect(described_class.deliverable_shape?(email)).to be(true), email }
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
