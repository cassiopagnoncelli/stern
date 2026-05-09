require "rails_helper"

# Covers the past-timestamp cascade branch of `create_entry` (db/functions/create_entry.sql):
# inserting an entry with `in_timestamp_utc` set to a past time recomputes
# `ending_balance` for every later row on the same (book_id, gid, currency).
# The non-cascade path is exercised by entry_spec.rb; this file targets the
# cascade math, the rejection paths, and the same-timestamp edge case.
module Stern
  RSpec.describe "Entry past-timestamp cascade", type: :model do
    let(:currency) { ::Stern.cur("BRL") }
    let(:book_id) { 1 }
    let(:gid) { 1101 }
    let(:base_time) { Time.current.beginning_of_minute - 1.hour }

    before { Repair.clear(confirm: true) }

    def create_entry!(amount:, timestamp:, entry_pair_id:)
      Entry.create!(book_id:, gid:, entry_pair_id:, amount:, currency:, timestamp:)
    end

    def cascade
      Entry.where(book_id:, gid:, currency:)
        .order(:timestamp, :id)
        .pluck(:amount, :ending_balance)
    end

    describe "linear series at increasing timestamps" do
      it "writes ending_balance as the running sum on each insert" do
        create_entry!(amount: 100, entry_pair_id: 1, timestamp: base_time - 4.hours)
        expect(cascade).to eq([ [ 100, 100 ] ])

        create_entry!(amount: 50, entry_pair_id: 2, timestamp: base_time - 3.hours)
        expect(cascade).to eq([ [ 100, 100 ], [ 50, 150 ] ])

        create_entry!(amount: -30, entry_pair_id: 3, timestamp: base_time - 2.hours)
        expect(cascade).to eq([ [ 100, 100 ], [ 50, 150 ], [ -30, 120 ] ])

        create_entry!(amount: 200, entry_pair_id: 4, timestamp: base_time - 1.hour)
        expect(cascade).to eq([ [ 100, 100 ], [ 50, 150 ], [ -30, 120 ], [ 200, 320 ] ])

        expect(Doctor.ending_balance_consistent?(book_id:, gid:, currency:)).to be(true)
      end
    end

    describe "insertion between two existing entries" do
      before do
        create_entry!(amount: 100, entry_pair_id: 1, timestamp: base_time - 4.hours)
        create_entry!(amount: 50, entry_pair_id: 2, timestamp: base_time - 3.hours)
        create_entry!(amount: -30, entry_pair_id: 3, timestamp: base_time - 2.hours)
        create_entry!(amount: 200, entry_pair_id: 4, timestamp: base_time - 1.hour)
      end

      let(:insert_ts) { base_time - 2.hours - 30.minutes }

      it "sets the inserted row's ending_balance to (prior partial sum + amount)" do
        # Prior partial sum at t-2.5h is +100 + +50 = 150.
        create_entry!(amount: 25, entry_pair_id: 5, timestamp: insert_ts)
        expect(Entry.find_by!(entry_pair_id: 5).ending_balance).to eq(175)
      end

      it "rewrites ALL downstream ending_balance values to fold in the inserted amount" do
        downstream_ids = Entry.where(book_id:, gid:, currency:)
          .where("timestamp > ?", insert_ts)
          .order(:timestamp, :id).pluck(:id)
        expect(Entry.where(id: downstream_ids).order(:timestamp, :id).pluck(:ending_balance))
          .to eq([ 120, 320 ])

        create_entry!(amount: 25, entry_pair_id: 5, timestamp: insert_ts)

        # Each downstream row is +25 from before: -30→145, 200→345.
        expect(Entry.where(id: downstream_ids).order(:timestamp, :id).pluck(:ending_balance))
          .to eq([ 145, 345 ])
        expect(cascade).to eq([
          [ 100, 100 ],
          [ 50, 150 ],
          [ 25, 175 ],
          [ -30, 145 ],
          [ 200, 345 ]
        ])
        expect(Doctor.ending_balance_consistent?(book_id:, gid:, currency:)).to be(true)
      end

      it "does not touch entries earlier than the inserted timestamp" do
        upstream_before = Entry.where(book_id:, gid:, currency:)
          .where("timestamp < ?", insert_ts)
          .order(:timestamp, :id).pluck(:id, :ending_balance)

        create_entry!(amount: 25, entry_pair_id: 5, timestamp: insert_ts)

        upstream_after = Entry.where(id: upstream_before.map(&:first))
          .order(:timestamp, :id).pluck(:id, :ending_balance)
        expect(upstream_after).to eq(upstream_before)
      end

      it "negative inserted amount cascades a decrease through downstream rows" do
        create_entry!(amount: -10, entry_pair_id: 5, timestamp: insert_ts)
        expect(cascade).to eq([
          [ 100, 100 ],
          [ 50, 150 ],
          [ -10, 140 ],
          [ -30, 110 ],
          [ 200, 310 ]
        ])
        expect(Doctor.ending_balance_consistent?(book_id:, gid:, currency:)).to be(true)
      end
    end

    describe "edge case: insertion at exactly an existing timestamp" do
      # The function's prior-balance lookup uses `timestamp < entry.timestamp`,
      # so an equal timestamp would compute against the existing row's
      # predecessor rather than the existing row itself. In practice the DB's
      # unique index on (book_id, gid, currency, timestamp) blocks the INSERT
      # before that arithmetic ever lands a row — so the operation is a hard
      # rejection, not a silent overwrite.
      it "raises duplicate-key and leaves the existing row's ending_balance intact" do
        ts = base_time - 2.hours
        create_entry!(amount: 100, entry_pair_id: 1, timestamp: ts)
        expect(Entry.find_by!(entry_pair_id: 1).ending_balance).to eq(100)

        expect {
          create_entry!(amount: 50, entry_pair_id: 2, timestamp: ts)
        }.to raise_error(ActiveRecord::StatementInvalid, /duplicate key/)
      end
    end

    describe "edge case: future timestamp rejection" do
      it "raises with the function's 'cannot be in the future' message" do
        expect {
          create_entry!(amount: 100, entry_pair_id: 1, timestamp: 1.hour.from_now)
        }.to raise_error(ActiveRecord::StatementInvalid, /cannot be in the future/)
      end
    end
  end
end
