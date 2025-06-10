Doctor.clear

Benchmark.measure do
  # Very conservative approach: use only 4 threads maximum to avoid connection issues
  max_threads = 4
  total_iterations = 1000
  
  # Create work items for each iteration
  work_items = (1..total_iterations).to_a
  
  # Process work in small batches with limited threads
  work_items.each_slice(max_threads) do |batch|
    threads = batch.map do |i|
      Thread.new do
        # Each thread gets its own connection and releases it immediately after each operation
        begin
          ActiveRecord::Base.connection_pool.with_connection do
            PayBoleto.new(payment_id: 2*i, merchant_id: 1101, amount: 250, fee: 50).call(idem_key: "boletinho_#{2*i}");
          end
          
          ActiveRecord::Base.connection_pool.with_connection do
            PayBoleto.new(payment_id: 2*i + 1, merchant_id: 1101, amount: 100, fee: 0).call(idem_key: "boletinho_#{2*i + 1}");
          end
        rescue => e
          puts "Error processing iteration #{i}: #{e.message}"
          raise
        end
      end
    end
    
    # Wait for current batch to complete
    threads.each(&:join)
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
