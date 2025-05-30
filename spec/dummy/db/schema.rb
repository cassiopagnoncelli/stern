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

ActiveRecord::Schema[8.0].define(version: 2023_05_24_123950) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "stern_books", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name", null: false
    t.index ["name"], name: "index_stern_books_on_name"
  end

  create_table "stern_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "book_id", null: false
    t.integer "gid", null: false
    t.bigint "entry_pair_id", null: false
    t.bigint "amount", null: false
    t.bigint "ending_balance", null: false
    t.datetime "timestamp", null: false
    t.index ["book_id", "gid", "entry_pair_id"], name: "index_stern_entries_on_book_id_and_gid_and_entry_pair_id", unique: true
    t.index ["book_id", "gid", "timestamp"], name: "index_stern_entries_on_book_id_and_gid_and_timestamp", unique: true
  end

  create_table "stern_entry_pairs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "code", null: false
    t.bigint "uid", null: false
    t.bigint "amount", null: false
    t.datetime "timestamp", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.bigint "credit_entry_pair_id"
    t.bigint "operation_id", null: false
    t.index ["code", "uid"], name: "index_stern_entry_pairs_on_code_and_uid", unique: true
    t.index ["operation_id"], name: "index_stern_entry_pairs_on_operation_id"
  end

  create_table "stern_operations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name", null: false
    t.integer "direction", null: false
    t.json "params", default: "{}", null: false
    t.index ["name"], name: "index_stern_operations_on_name"
  end

  create_table "stern_scheduled_operations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name", null: false
    t.json "params", default: {}, null: false
    t.datetime "after_time", null: false
    t.integer "status", default: 0, null: false
    t.datetime "status_time", null: false
    t.string "error_message"
    t.index ["after_time"], name: "index_stern_scheduled_operations_on_after_time"
    t.index ["name"], name: "index_stern_scheduled_operations_on_name"
    t.index ["status"], name: "index_stern_scheduled_operations_on_status"
  end
end
