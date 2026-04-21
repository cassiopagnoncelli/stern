FactoryBot.define do
  factory :entry_pair, class: "Stern::EntryPair" do
    code { ::Stern.chart.entry_pairs.values.first.name }
    uid { 1 }
    amount { 100 }
    timestamp { DateTime.current }
    operation_id { 1 }
  end
end
