FactoryBot.define do
  factory :entry, class: "Stern::Entry" do
    book_id { 1 }
    gid { 1 }
    entry_pair_id { 12345 }
    amount { 100 }
    timestamp { DateTime.current }
  end
end  
