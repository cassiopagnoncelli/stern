FactoryBot.define do
  factory :open_settlement, class: "Stern::OpenSettlement" do
    settlement_id { 33_000 }
    merchant_id { 1_101 }
    amount { 50_000 }

    trait :undo do
      merchant_id { nil }
      amount { nil }
    end
  end
end
