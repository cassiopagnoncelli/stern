class CreateSternBooks < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_books, if_not_exists: true do |t|
      t.timestamps

      t.string :name, null: false, unique: true, index: true
    end
  end
end
