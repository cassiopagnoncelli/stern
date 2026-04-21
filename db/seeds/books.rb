def seed_books
  Stern::BOOKS_CODES.each do |name, id|
    Stern::Book.find_or_create_by!(id:, name:)
    Rails.logger.info "Registered book #{name}"
  end
end
