FactoryBot.define do
  factory :scheduled_operation, class: "Stern::ScheduledOperation" do
    name { "ChargePix" }
    params { { charge_id: 1, payment_id: 1101, customer_id: 2, amount: 9900, currency: "usd" } }
    after_time { 1.minute.ago }
    status { :pending }
    status_time { Time.current }
  end
end
