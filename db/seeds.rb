Stern::BOOKS.each do |name, id|
  Stern::Book.find_or_create_by!(id:, name:)
end
