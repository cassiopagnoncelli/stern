FactoryBot.define do
  factory :tx, class: 'Stern::Tx' do
    code { STERN_TX_CODES[:add_balance] }
    uid { 1 }
    amount { 100 }
    timestamp { DateTime.current }
    credit_tx_id { nil }
  end
end
