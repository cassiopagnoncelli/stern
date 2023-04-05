Benchmark.measure do
  (1..1_000).each do |i|
    Stern::PayBoleto.new(payment_id: i, merchant_id: 1101, amount: 250, fee: 100).call
  end
end
