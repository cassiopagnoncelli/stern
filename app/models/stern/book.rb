# frozen_string_literal: true

module Stern
  class Book < ApplicationRecord
    has_many :entries, class_name: "Stern::Entry"

    validates :name, presence: true, uniqueness: true

    BOOKS.each do |book_name, id|
      define_singleton_method book_name.to_sym do
        Book.find(id)
      end
    end

    def self.code(book_name)
      BOOKS[book_name]
    end
  end
end
