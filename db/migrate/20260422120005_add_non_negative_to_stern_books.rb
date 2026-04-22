class AddNonNegativeToSternBooks < ActiveRecord::Migration[7.0]
  def up
    add_column :stern_books, :non_negative, :boolean, default: false, null: false

    ids = ::Stern.chart.books.each_value.select(&:non_negative).map(&:code)
    return if ids.empty?

    execute ActiveRecord::Base.sanitize_sql_array(
      [ "UPDATE stern_books SET non_negative = TRUE WHERE id IN (?)", ids ],
    )
  end

  def down
    remove_column :stern_books, :non_negative
  end
end
