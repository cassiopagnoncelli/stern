FactoryBot.define do
  factory :book, class: "Stern::Book" do
    sequence(:name) { |n| "factory_book_#{n}" }
  end
end
