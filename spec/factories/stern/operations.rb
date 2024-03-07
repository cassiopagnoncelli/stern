FactoryBot.define do
  factory :operation, class: "Stern::Operation" do
    operation_def_id { 1 }
    direction { :do }
    params { {} }
  end

  factory :open_settlement, class: "Stern::OpenSettlement" do
    settlement_id { 33_000 }
    merchant_id { 1_101 }
    amount { 50_000 }

    trait :undo do
      merchant_id { nil }
      amount { nil }
    end
  end

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

  factory :pay_pix, class: "Stern::PayPix" do
    payment_id { 29000 }
    merchant_id { 1101 }
    amount { 9900 }
    fee { 100 }

    trait :undo do
      merchant_id { nil }
      amount { nil }
      fee { nil }
    end
  end
end
