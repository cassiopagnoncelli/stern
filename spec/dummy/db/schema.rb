# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.0].define(version: 2023_05_22_052219) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "stern_books", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_stern_books_on_name"
  end

  create_table "stern_entries", force: :cascade do |t|
    t.integer "book_id", null: false
    t.integer "gid", null: false
    t.bigint "tx_id", null: false
    t.bigint "amount", null: false
    t.bigint "ending_balance", null: false
    t.datetime "timestamp", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["book_id", "gid", "timestamp"], name: "index_stern_entries_on_book_id_and_gid_and_timestamp", unique: true
    t.index ["book_id", "gid", "tx_id"], name: "index_stern_entries_on_book_id_and_gid_and_tx_id", unique: true
  end

  create_table "stern_operation_defs", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "active", null: false
    t.boolean "undo_capability", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_stern_operation_defs_on_name"
  end

  create_table "stern_operations", force: :cascade do |t|
    t.integer "operation_def_id", null: false
    t.integer "direction", null: false
    t.json "params", default: "{}", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["operation_def_id"], name: "index_stern_operations_on_operation_def_id"
  end

  create_table "stern_txs", force: :cascade do |t|
    t.integer "code", null: false
    t.bigint "uid", null: false
    t.bigint "amount", null: false
    t.datetime "timestamp", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.bigint "credit_tx_id"
    t.bigint "operation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code", "uid"], name: "index_stern_txs_on_code_and_uid", unique: true
    t.index ["operation_id"], name: "index_stern_txs_on_operation_id"
  end

end
