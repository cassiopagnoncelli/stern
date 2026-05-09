# frozen_string_literal: true

module Stern
  class Book < ApplicationRecord
    # Label emitted by `create_entry`/`destroy_entry` (in db/functions/) via
    # `RAISE EXCEPTION ... USING CONSTRAINT = '...'` when a write would leave
    # an `ending_balance < 0` on a `non_negative = true` book. Matched in
    # `Entry.non_negative_violation?` against PG's `PG_DIAG_CONSTRAINT_NAME`
    # diagnostic field. The string is a contract between the PL/pgSQL functions
    # and the Ruby rescue — keep both sides in lockstep.
    NON_NEGATIVE_CONSTRAINT = "stern_books_non_negative".freeze

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
