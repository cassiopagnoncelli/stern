require 'rails_helper'

module Stern
  # Dummy subclass to test BaseOperation functionality
  class DummyOperation < BaseOperation
    UID = 1

    def perform(operation_id)
      "perform called with #{operation_id}"
    end

    def perform_undo
      "undo called"
    end
  end
end

RSpec.describe Stern::DummyOperation, type: :model do
  subject(:operation) { described_class.new }

  describe '#call' do
    context 'when direction is :do' do
      before do
        allow(operation).to receive(:lock_tables)
        allow(operation).to receive(:perform)
      end

      it 'wraps in a transaction when transaction is true' do
        expect { operation.call(direction: :do) }.not_to raise_error
      end

      it 'calls perform method' do
        allow(ApplicationRecord).to receive(:transaction).and_yield
        expect { operation.call(direction: :do) }.not_to raise_error
      end
    end

    context 'when direction is :undo' do
      it 'calls perform_undo method' do
        allow(ApplicationRecord).to receive(:transaction).and_yield
        expect(operation).to receive(:perform_undo)
        operation.call(direction: :undo)
      end
    end

    context 'with invalid direction' do
      it 'raises ArgumentError' do
        expect { operation.call(direction: :invalid) }.to raise_error(ArgumentError)
      end
    end
  end

  describe '#call_undo' do
    it 'calls the perform_undo method' do
      allow(ApplicationRecord).to receive(:transaction).and_yield
      expect(operation).to receive(:perform_undo)
      operation.call_undo
    end
  end
end
