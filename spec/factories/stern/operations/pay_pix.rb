FactoryBot.define do
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
