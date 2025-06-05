Doctor.clear

Benchmark.measure do
  (1..100).each do |i|
    PayBoleto.new(payment_id: 2*i, merchant_id: 1101, amount: 250, fee: 50).call(idem_key: "boletinho_#{2*i}")
    PayBoleto.new(payment_id: 2*i + 1, merchant_id: 1101, amount: 100, fee: 0).call(idem_key: "boletinho_#{2*i + 1}")
  end
end

Entry.all.each(&:destroy!)
EntryPair.all.each(&:destroy!)

__END__

SELECT
  sb.id AS book_id,
  sb.name,
  gid,
  COUNT(*) AS n,
  MIN(amount) AS amount_min,
  MAX(amount) AS amount_max,
  MIN(ending_balance) AS balance_min,
  MAX(ending_balance) AS balance_max
FROM stern_entries se
JOIN stern_books sb ON se.book_id = sb.id
GROUP BY sb.id, gid
ORDER BY sb.id, gid;
