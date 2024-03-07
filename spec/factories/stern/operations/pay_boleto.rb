FactoryBot.define do
  factory :pay_boleto, class: "Stern::PayBoleto" do
    payment_id { 31_000 }
    merchant_id { 1_101 }
    amount { 9_900 }
    fee { 100 }

    trait :undo do
      merchant_id { nil }
      amount { nil }
      fee { nil }
    end
  end
end
