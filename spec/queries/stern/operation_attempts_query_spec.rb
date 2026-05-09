require "rails_helper"

module Stern
  RSpec.describe OperationAttemptsQuery, type: :model do
    let(:base_time) { Time.utc(2026, 5, 1, 12, 0) }

    def make_attempt(name: "ChargePayment", status: :success, idem_key: nil, attempted_at: base_time, **rest)
      OperationAttempt.create!(
        name: name,
        params: {},
        idem_key: idem_key,
        status: status,
        attempted_at: attempted_at,
        **rest
      )
    end

    describe "argument validation" do
      it "rejects non-positive page" do
        expect { described_class.new(page: 0) }.to raise_error(ArgumentError, /page must be positive/)
      end

      it "rejects non-positive per_page" do
        expect { described_class.new(per_page: 0) }.to raise_error(ArgumentError, /per_page must be positive/)
      end

      it "rejects an unknown status" do
        expect { described_class.new(status: "wat") }.to raise_error(ArgumentError, /unknown status/)
      end

      it "accepts known statuses by string or symbol" do
        expect { described_class.new(status: "success") }.not_to raise_error
        expect { described_class.new(status: :failed) }.not_to raise_error
      end

      it "treats blank filters as 'no filter'" do
        q = described_class.new(name: "", status: "", idem_key: "")
        expect(q.name).to be_nil
        expect(q.status).to be_nil
        expect(q.idem_key).to be_nil
      end
    end

    describe "#call" do
      before { OperationAttempt.delete_all }

      it "orders by attempted_at desc, id desc" do
        a = make_attempt(attempted_at: base_time)
        b = make_attempt(attempted_at: base_time + 1.minute)
        c = make_attempt(attempted_at: base_time + 1.minute) # same timestamp as b — id breaks the tie

        result = described_class.new.call.to_a
        expect(result.map(&:id)).to eq([ c.id, b.id, a.id ])
      end

      it "filters by name" do
        make_attempt(name: "ChargePayment")
        make_attempt(name: "Deposit")

        result = described_class.new(name: "Deposit").call.to_a
        expect(result.map(&:name)).to eq([ "Deposit" ])
      end

      it "filters by status" do
        make_attempt(status: :success)
        make_attempt(status: :failed)

        result = described_class.new(status: :failed).call.to_a
        expect(result.map(&:status)).to eq([ "failed" ])
      end

      it "filters by idem_key (exact match)" do
        make_attempt(idem_key: "abc-12345")
        make_attempt(idem_key: "xyz-67890")

        result = described_class.new(idem_key: "xyz-67890").call.to_a
        expect(result.map(&:idem_key)).to eq([ "xyz-67890" ])
      end

      it "filters by attempted_at window (inclusive bounds)" do
        make_attempt(attempted_at: base_time - 1.day) # before window
        in_window = make_attempt(attempted_at: base_time)
        make_attempt(attempted_at: base_time + 2.days) # after window

        result = described_class.new(
          start_date: base_time - 1.hour,
          end_date: base_time + 1.hour,
        ).call.to_a
        expect(result.map(&:id)).to eq([ in_window.id ])
      end

      it "paginates with limit/offset" do
        ids = 5.times.map { |i| make_attempt(attempted_at: base_time + i.minutes).id }

        page_1 = described_class.new(per_page: 2, page: 1).call.to_a.map(&:id)
        page_2 = described_class.new(per_page: 2, page: 2).call.to_a.map(&:id)

        # desc order — newest first
        expect(page_1).to eq([ ids[4], ids[3] ])
        expect(page_2).to eq([ ids[2], ids[1] ])
      end
    end

    describe "#total_count" do
      before { OperationAttempt.delete_all }

      it "returns the unpaginated count" do
        3.times { make_attempt }
        expect(described_class.new(per_page: 1).total_count).to eq(3)
      end

      it "respects filters" do
        make_attempt(status: :success)
        make_attempt(status: :failed)
        make_attempt(status: :failed)

        expect(described_class.new(status: :failed).total_count).to eq(2)
      end
    end
  end
end
