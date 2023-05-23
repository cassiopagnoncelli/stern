# require Rails.root.join('..', '..', 'db', 'seeds', 'books.rb')
# require Rails.root.join('..', '..', 'db', 'seeds', 'operation_defs.rb')

require_relative 'seeds/books'
require_relative 'seeds/operation_defs'

seed_books
seed_operation_defs
