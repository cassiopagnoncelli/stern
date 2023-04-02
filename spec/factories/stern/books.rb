FactoryBot.define do
  factory :book, class: 'Stern::Book' do
    id { 1 }
    name { "balance" }
  end
end
