require "rails_helper"

# DB-level backstop for the never-negative invariant.
#
# Charts can mark a book `non_negative: true`; `create_entry` and `destroy_entry`
# then refuse any write that would leave `ending_balance < 0` on that book.
# This file exercises the DB backstop directly — see balance_invariant_spec for
# the app-level pre-check path (both layers coexist intentionally).
module Stern
  RSpec.describe "Chart-level non_negative constraint", type: :model do
    self.use_transactional_tests = false

    let(:brl) { ::Stern.cur("BRL") }
    let(:flagged_book_id) { ::Stern.chart.book_code(:merchant_credit) }

    before { Repair.clear }
    after { Repair.clear }

    def new_op
      Operation.create!(name: "nn_test", params: {})
    end

    def seed(gid:, amount:)
      EntryPair.add_merchant_credit(
        SecureRandom.random_number(1 << 30), gid, amount, brl, operation_id: new_op.id,
      )
    end

    def negative_rows(gid)
      Entry.where(book_id: flagged_book_id, gid:, currency: brl)
        .where("ending_balance < 0").pluck(:id, :amount, :ending_balance)
    end

    describe "seeded flag state" do
      it "marks merchant_credit as non_negative in stern_books" do
        expect(Book.find(flagged_book_id).non_negative).to be(true)
      end

      it "leaves counterpart merchant_credit_0 permissive" do
        expect(Book.find(::Stern.chart.book_code(:merchant_credit_0)).non_negative).to be(false)
      end

      it "leaves merchant_adjusted permissive" do
        expect(Book.find(::Stern.chart.book_code(:merchant_adjusted)).non_negative).to be(false)
      end
    end

    describe "direct EntryPair.add_* overdraft" do
      it "raises BalanceNonNegativeViolation and commits no rows" do
        gid = 970_101
        before_count = Entry.where(book_id: flagged_book_id, gid:).count

        expect {
          EntryPair.add_merchant_credit(
            SecureRandom.random_number(1 << 30), gid, -100, brl, operation_id: new_op.id,
          )
        }.to raise_error(::Stern::BalanceNonNegativeViolation)

        after_count = Entry.where(book_id: flagged_book_id, gid:).count
        expect(after_count).to eq(before_count)
      end

      it "raises InsufficientFunds for callers rescuing the parent class" do
        gid = 970_102
        expect {
          EntryPair.add_merchant_credit(
            SecureRandom.random_number(1 << 30), gid, -5, brl, operation_id: new_op.id,
          )
        }.to raise_error(::Stern::InsufficientFunds)
      end

      it "allows the counterpart _0 book to go negative (double-entry needs it)" do
        gid = 970_103
        expect {
          EntryPair.add_merchant_credit(
            SecureRandom.random_number(1 << 30), gid, 50, brl, operation_id: new_op.id,
          )
        }.not_to raise_error

        zero_book_id = ::Stern.chart.book_code(:merchant_credit_0)
        expect(Entry.where(book_id: zero_book_id, gid:, currency: brl).sum(:amount)).to eq(-50)
      end
    end

    describe "operation that forgets the app-level pre-check" do
      it "still cannot corrupt the invariant — DB refuses" do
        gid = 970_201
        seed(gid:, amount: 50)

        forgetful = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :amount, :currency

          def target_tuples
            tuples_for_pair(:merchant_credit, merchant_id, merchant_id, currency)
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_credit(
              uid, merchant_id, amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::ForgetfulWithdraw", forgetful)

        expect {
          ForgetfulWithdraw.new(merchant_id: gid, uid: 7001, amount: -100, currency: brl).call
        }.to raise_error(::Stern::BalanceNonNegativeViolation)

        expect(::Stern.balance(gid, :merchant_credit, brl)).to eq(50)
        expect(negative_rows(gid)).to eq([])
      end
    end

    describe "concurrent forgetful withdraws" do
      it "no row ever reaches negative ending_balance under parallel overdrafts" do
        gid = 970_301
        seed(gid:, amount: 100)

        forgetful = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :amount, :currency

          def target_tuples
            tuples_for_pair(:merchant_credit, merchant_id, merchant_id, currency)
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_credit(
              uid, merchant_id, amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::ForgetfulStorm", forgetful)

        outcomes = Queue.new
        threads = 20.times.map do |i|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              ForgetfulStorm.new(merchant_id: gid, uid: 80_000 + i, amount: -10, currency: brl).call
              outcomes << :ok
            rescue ::Stern::BalanceNonNegativeViolation
              outcomes << :rejected
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        results = []
        results << outcomes.pop until outcomes.empty?

        expect(results.count(:ok)).to eq(10)
        expect(results.count(:rejected)).to eq(10)
        expect(::Stern.balance(gid, :merchant_credit, brl)).to eq(0)
        expect(negative_rows(gid)).to eq([])
      end
    end

    describe "past-timestamp inserts" do
      it "raises when the inserted row itself would be negative" do
        gid = 970_401
        seed(gid:, amount: 100)

        expect {
          EntryPair.add_merchant_credit(
            SecureRandom.random_number(1 << 30), gid, -500, brl,
            timestamp: 1.hour.ago, operation_id: new_op.id,
          )
        }.to raise_error(::Stern::BalanceNonNegativeViolation)

        expect(negative_rows(gid)).to eq([])
      end

      it "raises when a later cascaded row would become negative" do
        gid = 970_402

        EntryPair.add_merchant_credit(
          SecureRandom.random_number(1 << 30), gid, 100, brl,
          timestamp: 3.hours.ago, operation_id: new_op.id,
        )
        EntryPair.add_merchant_credit(
          SecureRandom.random_number(1 << 30), gid, -80, brl,
          timestamp: 1.hour.ago, operation_id: new_op.id,
        )

        expect(::Stern.balance(gid, :merchant_credit, brl)).to eq(20)

        expect {
          EntryPair.add_merchant_credit(
            SecureRandom.random_number(1 << 30), gid, -50, brl,
            timestamp: 2.hours.ago, operation_id: new_op.id,
          )
        }.to raise_error(::Stern::BalanceNonNegativeViolation)

        expect(negative_rows(gid)).to eq([])
        expect(::Stern.balance(gid, :merchant_credit, brl)).to eq(20)
      end
    end

    describe "destroy_entry cascade" do
      it "raises when destroying a row would drive subsequent rows negative" do
        gid = 970_501

        EntryPair.add_merchant_credit(
          SecureRandom.random_number(1 << 30), gid, 100, brl,
          timestamp: 2.hours.ago, operation_id: new_op.id,
        )
        EntryPair.add_merchant_credit(
          SecureRandom.random_number(1 << 30), gid, -80, brl,
          timestamp: 1.hour.ago, operation_id: new_op.id,
        )

        positive_entry = Entry.where(book_id: flagged_book_id, gid:, currency: brl, amount: 100).first

        expect { positive_entry.destroy! }.to raise_error(::Stern::BalanceNonNegativeViolation)

        expect(negative_rows(gid)).to eq([])
        expect(Entry.where(book_id: flagged_book_id, gid:, currency: brl).count).to eq(2)
      end
    end

    describe "layer separation — app pre-check fires first when present" do
      it "raises InsufficientFunds (parent class) without invoking the DB check" do
        gid = 970_601
        seed(gid:, amount: 10)

        checked = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :amount, :currency

          def target_tuples
            tuples_for_pair(:merchant_credit, merchant_id, merchant_id, currency)
          end

          def perform(operation_id)
            balance = ::Stern.balance(merchant_id, :merchant_credit, currency)
            raise ::Stern::InsufficientFunds if balance + amount < 0

            ::Stern::EntryPair.add_merchant_credit(
              uid, merchant_id, amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::CheckedWithdraw", checked)

        expect {
          CheckedWithdraw.new(merchant_id: gid, uid: 9001, amount: -50, currency: brl).call
        }.to raise_error { |err|
          expect(err).to be_a(::Stern::InsufficientFunds)
          expect(err).not_to be_a(::Stern::BalanceNonNegativeViolation)
        }
      end
    end

    # MIXED-style concurrent overdraft: some threads go through the
    # app-level pre-check (raising InsufficientFunds), others bypass it
    # and rely on the DB backstop (raising BalanceNonNegativeViolation).
    # Both error classes must coexist cleanly — a caller rescuing
    # `InsufficientFunds` catches both, and the ledger stays consistent
    # regardless of which layer fired.
    describe "concurrent mix of app-pre-check and DB-only overdrafts" do
      it "exactly one withdraw succeeds; all others raise some InsufficientFunds flavor" do
        gid = 970_701
        seed(gid:, amount: 100)

        checked = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :amount, :currency

          def target_tuples
            tuples_for_pair(:merchant_credit, merchant_id, merchant_id, currency)
          end

          def perform(operation_id)
            balance = ::Stern.balance(merchant_id, :merchant_credit, currency)
            raise ::Stern::InsufficientFunds if balance + amount < 0

            ::Stern::EntryPair.add_merchant_credit(
              uid, merchant_id, amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::CheckedMixWithdraw", checked)

        forgetful = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :amount, :currency

          def target_tuples
            tuples_for_pair(:merchant_credit, merchant_id, merchant_id, currency)
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_credit(
              uid, merchant_id, amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::ForgetfulMixWithdraw", forgetful)

        insufficient = Concurrent::AtomicFixnum.new(0)
        nn_violation = Concurrent::AtomicFixnum.new(0)
        successes    = Concurrent::AtomicFixnum.new(0)
        other        = Queue.new

        # Alternate styles across threads. With seed=100 and amount=-80,
        # exactly one withdraw fits; everyone else overdrafts. The op
        # class drives which error surfaces.
        threads = 10.times.map do |i|
          klass = i.even? ? ::Stern::CheckedMixWithdraw : ::Stern::ForgetfulMixWithdraw
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              klass.new(merchant_id: gid, uid: 77_000 + i, amount: -80, currency: brl).call
              successes.increment
            rescue ::Stern::BalanceNonNegativeViolation
              nn_violation.increment
            rescue ::Stern::InsufficientFunds
              # Parent class — checked path's raise lands here. Order
              # matters: rescue the subclass FIRST above, or this branch
              # would swallow both.
              insufficient.increment
            rescue StandardError => e
              other << [ e.class.name, e.message ]
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        others = []
        others << other.pop until other.empty?
        expect(others).to be_empty,
          "expected only InsufficientFunds / BalanceNonNegativeViolation, got: #{others.inspect}"

        # Exactly one winner.
        expect(successes.value).to eq(1)
        expect(insufficient.value + nn_violation.value).to eq(9)

        # Both error layers actually fired under the race — otherwise the
        # test isn't exercising the interplay, just a single path. With
        # 10 interleaved threads the race should reliably surface each
        # layer at least once, though under heavy serialization one side
        # may dominate, so we only assert the sum.

        # Final state: balance == 20 (100 - 80), no negative rows, cascade
        # consistent, no duplicate ending_balance (monotonic sequence).
        expect(::Stern.balance(gid, :merchant_credit, brl)).to eq(20)
        expect(negative_rows(gid)).to eq([])
        expect(Doctor.ending_balance_consistent?(book_id: flagged_book_id, gid:, currency: brl)).to be(true)

        all_ending = Entry.where(book_id: flagged_book_id, gid:, currency: brl).pluck(:ending_balance)
        expect(all_ending).to eq(all_ending.uniq)
      end
    end
  end
end
