require 'rails_helper'

module Stern
  RSpec.describe Doctor, type: :model do
    describe ".consistent?" do
      it "always true" do
        expect(described_class.consistent?).to be_truthy
      end
    end

    describe ".rebuild_book_gid_balance" do
      it "executes an SQL query" do
        expect(ActiveRecord::Base.connection).to receive(:execute)
        described_class.rebuild_book_gid_balance(1, 1)
      end
    end

    describe ".rebuild_gid_balance" do
      it "rebuilds based on gid" do
        expect(described_class).to receive(:rebuild_book_gid_balance).at_least(1).times
        described_class.rebuild_gid_balance(1)
      end
    end

    describe ".rebuild_balances" do
      it "raises error if not confirmed" do
        expect{ described_class.rebuild_balances }.to raise_error(OperationNotConfirmedError)
      end

      it "rebuilds if confirmed" do
        allow(described_class).to receive(:rebuild_gid_balance)
        described_class.rebuild_balances(true)
      end
    end
  end
end
