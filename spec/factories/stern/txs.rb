FactoryBot.define do
  factory :tx, class: "Stern::Tx" do
    code { TX_ENTRIES[:add_balance] }
    uid { 1 }
    amount { 100 }
    timestamp { DateTime.current }
    credit_tx_id { nil }
    operation_id { 1 }
  end
end
