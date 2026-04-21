FactoryBot.define do
  factory :entry_pair, class: "Stern::EntryPair" do
    code { STERN_DEFS[:entry_pairs][:add_balance] }
    uid { 1 }
    amount { 100 }
    timestamp { DateTime.current }
    operation_id { 1 }
  end
end
