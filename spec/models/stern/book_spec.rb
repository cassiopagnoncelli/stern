require 'rails_helper'

module Stern
  RSpec.describe Book, type: :model do
    subject(:book) { build :book }

    before { book.save! }

    let(:book_name) { BOOKS.keys.first.to_sym }

    describe "validations" do
      it { should validate_presence_of(:name) }
      it { should have_many(:entries) }
    end

    describe ".code" do
      it "fetches the book code" do
        book_id = BOOKS[book_name]
        expect(described_class.code(book_name)).to eq(book_id)
      end
    end

    describe "books selectors" do
      before { create :book, id: BOOKS[book_name], name: book_name }

      it "accepts a call by book name" do
        allow(described_class).to receive(book_name)
        described_class.public_send(book_name)
      end

      it "finds the book by calling its name" do
        expect(described_class.public_send(book_name).id).to eq(BOOKS[book_name])
      end
    end
  end
end
