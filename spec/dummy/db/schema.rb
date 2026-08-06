# frozen_string_literal: true

ActiveRecord::Schema[8.0].define(version: 2026_08_06_000000) do
  enable_extension "pg_ripple"

  create_table "accounts", force: :cascade do |t|
    t.string "name"
    t.timestamps
  end

  create_table "people", force: :cascade do |t|
    t.bigint "account_id"
    t.string "name"
    t.string "email"
    t.date "born_on"
    t.boolean "active", default: true, null: false
    t.string "iri"
    t.timestamps
    t.index ["account_id"]
    t.index ["iri"], unique: true
  end
end
