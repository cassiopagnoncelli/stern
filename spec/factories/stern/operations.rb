FactoryBot.define do
  factory :operation, class: "Stern::Operation" do
    operation_def_id { 1 }
    direction { :do }
    params { {} }
  end
end
