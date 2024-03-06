FactoryBot.define do
  factory :operation_def, class: "Stern::OperationDef" do
    name { "PayPix" }
    active { true }
    undo_capability { true }
  end
end
