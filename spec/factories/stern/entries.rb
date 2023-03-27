FactoryBot.define do
  factory :entry do
    book_id { 1 }
    gid { 1 }
    tx_id { 12345 }
    amount { 9900 }
  end
end
