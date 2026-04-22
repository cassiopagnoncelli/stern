FactoryBot.define do
  factory :operation, class: "Stern::Operation" do
    name { "operation_name" }
    params { {} }
  end
end
