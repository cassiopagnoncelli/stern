class CreateSternBooks < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_books, if_not_exists: true do |t|
      t.string :name, null: false, unique: true, index: true

      t.timestamps
    end
  end
end
