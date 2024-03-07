module Stern
  RSpec.shared_examples "an operation call" do
    before do
      allow(operation).to receive(:lock_tables)
      allow(operation).to receive(:perform)
      allow(operation).to receive(:perform_undo)
    end

    it "performs the do operation within a transaction locking tables" do
      operation.call(direction: :do, transaction: true)
      expect(operation).to have_received(:perform)
      expect(operation).to have_received(:lock_tables)
    end

    it "performs the undo operation within a transaction locking tables" do
      operation.call(direction: :undo, transaction: true)
      expect(operation).to have_received(:perform_undo)
      expect(operation).to have_received(:lock_tables)
    end

    it "raises an ArgumentError when an invalid direction is given" do
      expect {
        operation.call(direction: :invalid)
      }.to raise_error(ArgumentError, "provide `direction` with :do or :undo")
    end

    describe "linked operation" do
      context "when direction is forwards" do
        it "records the operation" do
          expect {
            operation.call(direction: :do, transaction: true)
          }.to change(Operation, :count).by(1)
        end
      end

      context "when direction is backwards" do
        it "records the operation" do
          expect {
            operation.call(direction: :undo, transaction: true)
          }.to change(Operation, :count).by(1)
        end
      end
    end
  end
end
