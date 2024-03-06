FactoryBot.define do
  factory :scheduled_operation, class: "Stern::ScheduledOperation" do
    operation_def_id { 1 }
    params { { payment_id: 888, merchant_id: 1101, amount: 9900, fee: 250 } }
    after_time { "2023-05-24 09:39:50" }
    status { :pending }
    status_time { "2023-05-24 09:39:50" }
  end
end
