RSpec.configure do |config|
  config.before(:suite) do
    ::Stern.chart.books.each_value do |book|
      record = Stern::Book.find_or_initialize_by(id: book.code)
      record.name = book.name
      record.non_negative = book.non_negative
      record.save!
    end
  end
end
