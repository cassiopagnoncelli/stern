# frozen_string_literal: true

module Stern
  class Book < ApplicationRecord
    has_many :entries, class_name: "Stern::Entry", dependent: :restrict_with_exception

    validates :name, presence: true, uniqueness: true

    ::Stern.chart.books.each do |name, book|
      define_singleton_method(name) { Book.find(book.code) }
    end

    def self.code(book_name)
      ::Stern.chart.book_code(book_name)
    end
  end
end
