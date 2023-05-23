FactoryBot.define do
  factory :operation, class: 'Stern::Operation' do
    name { "PayPix" }
    direction { :do }
    params { {} }
  end
end
