def seed_books
  ::Stern.chart.books.each_value do |book|
    Stern::Book.find_or_create_by!(id: book.code, name: book.name)
    Rails.logger.info "Registered book #{book.name}"
  end
end
