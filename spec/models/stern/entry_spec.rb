require "rails_helper"

module Stern
  RSpec.describe Entry, type: :model do
    let(:currency) { ::Stern.cur("BRL") }

    # Repair.clear wipes EntryPairs and Operations alongside Entries, so the
    # FK from stern_entries.entry_pair_id has nothing to point at unless we
    # re-seed. Helpers below allocate a pair (and the backing operation)
    # lazily, with the synthetic `id` the test wants to reference.
    def spec_operation
      @spec_operation ||= Operation.create!(name: "entry_spec", params: {})
    end

    def seed_pair!(id:, currency: ::Stern.cur("BRL"))
      EntryPair.create!(
        id:, code: :withhold_merchant_balance, uid: 1101, amount: 1, currency:,
        timestamp: 100.years.ago, operation_id: spec_operation.id,
      )
    end

    def gen_entry(amount: 100, timestamp: nil)
      Repair.clear(confirm: true)
      @spec_operation = nil
      seed_pair!(id: 1)
      described_class.create!(book_id: 1, gid: 1101, entry_pair_id: 1, amount:, currency:, timestamp:)
    end

    # `Entry.create!` wrapper for the running-balance / last_entry blocks
    # that exercise multiple synthetic pair_ids per test.
    def mk_entry!(entry_pair_id:, amount:, currency: ::Stern.cur("BRL"), timestamp: nil, book_id: 1, gid: 1101)
      seed_pair!(id: entry_pair_id, currency:) unless EntryPair.exists?(id: entry_pair_id)
      described_class.create!(book_id:, gid:, entry_pair_id:, amount:, currency:, timestamp:)
    end

    describe "validations" do
      it { should validate_presence_of(:book_id) }
      it { should validate_presence_of(:gid) }
      it { should validate_presence_of(:entry_pair_id) }
      it { should validate_presence_of(:currency) }
      it { should validate_presence_of(:amount) }
      it { should allow_value(DateTime.current.last_week).for(:timestamp) }
      it { should belong_to(:entry_pair).class_name("Stern::EntryPair").optional }
      it { should belong_to(:book).class_name("Stern::Book").optional }
    end

    context "when creating" do
      it "creates without timestamp" do
        expect { gen_entry }.to change(described_class, :count).by(1)
      end

      it "creates with past timestamp" do
        expect {
          gen_entry(timestamp: DateTime.current - 1.day)
        }.to change(described_class, :count).by(1)
      end

      it "does not create for future timestamp" do
        expect {
          gen_entry(timestamp: DateTime.current + 1.day)
        }.to raise_error(ActiveRecord::StatementInvalid)
      end

      it "does not create with empty amount" do
        expect { gen_entry(amount: 0) }.to raise_error(ActiveRecord::StatementInvalid)
      end

      it "does not create without bang operator" do
        expect {
          described_class.create(book_id: 1, gid: 1101, entry_pair_id: 1, amount: 100, currency:, timestamp: nil)
        }.to raise_error(NotImplementedError, "Use create! instead")
      end
    end

    context "when updating" do
      subject(:entry) { described_class.first }
      let(:message) { "Entry records cannot be updated by design" }

      before { gen_entry(amount: 100) }

      it "raises error with update!" do
        expect { entry.update!(amount: 150) }.to raise_error(NotImplementedError, message)
      end

      it "raises error with update" do
        expect { entry.update(amount: 120) }.to raise_error(NotImplementedError, message)
        expect {
          entry.assign_attributes(amount: 140)
          entry.save
        }.to raise_error(NotImplementedError, message)
      end

      it "raises error with update_all" do
        expect {
          described_class.update_all(amount: 101) # rubocop:disable Rails/SkipsModelValidations
        }.to raise_error(NotImplementedError, message)
      end
    end

    context "when destroying" do
      subject(:entry) { described_class.first }

      before { gen_entry }

      it "raises error with destroy" do
        expect { entry.destroy }.to raise_error(NotImplementedError, "Use destroy! instead")
      end

      it "destroy! removes the record" do
        expect { entry.destroy! }.to change(described_class, :count).by(-1)
      end

      it "destroy_all is unopinionated" do
        expect { entry; Entry.destroy_all }.to raise_error(NotImplementedError)
      end
    end

    describe ".last_entry" do
      before { gen_entry }

      it "returns a record" do
        expect(described_class.last_entry(1, 1101, currency, DateTime.current).count).to be(1)
      end

      context "with entries in multiple currencies" do
        let(:usd) { ::Stern.cur("USD") }

        before do
          mk_entry!(entry_pair_id: 2, amount: 200, currency: usd)
        end

        it "scopes to the requested currency" do
          brl_row = described_class.last_entry(1, 1101, currency, DateTime.current).first
          usd_row = described_class.last_entry(1, 1101, usd, DateTime.current).first
          expect(brl_row.amount).to eq(100)
          expect(usd_row.amount).to eq(200)
        end

        it "returns no rows for a currency with no entries" do
          eur = ::Stern.cur("EUR")
          expect(described_class.last_entry(1, 1101, eur, DateTime.current).count).to eq(0)
        end
      end
    end

    describe "running balance" do
      let(:usd) { ::Stern.cur("USD") }

      before do
        Repair.clear(confirm: true)
        @spec_operation = nil
      end

      it "starts each currency's ending_balance from zero" do
        mk_entry!(entry_pair_id: 1, amount: 100, currency:)
        mk_entry!(entry_pair_id: 2, amount: 200, currency: usd)

        expect(described_class.find_by!(currency:).ending_balance).to eq(100)
        expect(described_class.find_by!(currency: usd).ending_balance).to eq(200)
      end

      it "sums within a currency without leaking into another currency" do
        mk_entry!(entry_pair_id: 1, amount: 100, currency:)
        mk_entry!(entry_pair_id: 2, amount: 200, currency: usd)
        mk_entry!(entry_pair_id: 3, amount: 50, currency:)
        mk_entry!(entry_pair_id: 4, amount: -80, currency: usd)

        brl_balances = described_class.where(currency:).order(:timestamp, :id).pluck(:ending_balance)
        usd_balances = described_class.where(currency: usd).order(:timestamp, :id).pluck(:ending_balance)
        expect(brl_balances).to eq([ 100, 150 ])
        expect(usd_balances).to eq([ 200, 120 ])
      end

      it "keeps (book_id, gid) partitioned separately by currency for same-ts uniqueness" do
        ts = DateTime.current - 1.hour
        mk_entry!(entry_pair_id: 1, amount: 100, currency:, timestamp: ts)
        expect {
          mk_entry!(entry_pair_id: 2, amount: 200, currency: usd, timestamp: ts)
        }.to change(described_class, :count).by(1)
      end

      it "rejects duplicate (book_id, gid, currency, timestamp)" do
        ts = DateTime.current - 1.hour
        mk_entry!(entry_pair_id: 1, amount: 100, currency:, timestamp: ts)
        expect {
          mk_entry!(entry_pair_id: 2, amount: 50, currency:, timestamp: ts)
        }.to raise_error(ActiveRecord::StatementInvalid, /duplicate key/)
      end

      it "cascades ending_balance recalc only within the inserting currency" do
        now = DateTime.current
        mk_entry!(entry_pair_id: 1, amount: 100, currency:, timestamp: now - 2.hours)
        mk_entry!(entry_pair_id: 2, amount: 50, currency:, timestamp: now - 1.hour)
        mk_entry!(entry_pair_id: 3, amount: 999, currency: usd, timestamp: now - 1.hour)

        # Insert a past entry in BRL — this must cascade across BRL, not USD.
        mk_entry!(entry_pair_id: 4, amount: 10, currency:, timestamp: now - 3.hours)

        brl = described_class.where(currency:).order(:timestamp, :id).pluck(:amount, :ending_balance)
        usd_balance = described_class.find_by!(currency: usd).ending_balance
        expect(brl).to eq([ [ 10, 10 ], [ 100, 110 ], [ 50, 160 ] ])
        expect(usd_balance).to eq(999)
      end
    end
  end
end
