require "rails_helper"

module Stern
  RSpec.describe OperationAttempt, type: :model do
    describe "schema" do
      it "has the documented columns" do
        cols = described_class.column_names
        %w[name params idem_key operation_id status error_class error_message error_backtrace attempted_at]
          .each { |c| expect(cols).to include(c) }
      end

      it "has the three documented statuses" do
        expect(described_class.statuses.keys).to contain_exactly("pending", "success", "failed")
      end
    end

    describe "validations" do
      it "requires name" do
        expect(described_class.new(status: :pending, attempted_at: Time.current)).not_to be_valid
      end

      it "requires attempted_at" do
        expect(described_class.new(name: "X", status: :pending)).not_to be_valid
      end
    end

    describe "linkage to Operation" do
      it "is optional (failed attempts have no Operation row)" do
        attempt = described_class.create!(
          name: "X", params: {}, status: :failed, attempted_at: Time.current,
          error_class: "RuntimeError", error_message: "boom",
        )
        expect(attempt.operation).to be_nil
      end
    end
  end

  RSpec.describe BaseOperation, "OperationAttempt integration", type: :model do
    let(:test_class) do
      Class.new(described_class) do
        inputs :a, :b
        attr_reader :perform_calls

        def perform(_)
          @perform_calls ||= []
          @perform_calls << :ran
        end
      end
    end

    let(:raising_class) do
      Class.new(described_class) do
        inputs :a

        def perform(_)
          raise RuntimeError, "perform exploded"
        end
      end
    end

    before do
      stub_const("Stern::TestOp", test_class)
      stub_const("Stern::RaisingOp", raising_class)
    end

    describe "successful call" do
      it "records a :success attempt linked to the committed Operation" do
        op = test_class.new(a: 1, b: 2)
        op_id = op.call(transaction: false)

        attempt = OperationAttempt.last
        expect(attempt).to have_attributes(
          name: "TestOp",
          status: "success",
          operation_id: op_id,
          error_class: nil,
        )
        expect(attempt.attempted_at).to be_within(2.seconds).of(Time.current)
      end

      it "stores params in the JSON-normalized shape" do
        test_class.new(a: 1, b: 2).call(transaction: false)
        expect(OperationAttempt.last.params).to eq("a" => 1, "b" => 2)
      end
    end

    describe "failed call" do
      it "records a :failed attempt with the error class, message, and backtrace" do
        expect {
          raising_class.new(a: 1).call(transaction: false)
        }.to raise_error(RuntimeError, "perform exploded")

        attempt = OperationAttempt.last
        expect(attempt).to have_attributes(
          name: "RaisingOp",
          status: "failed",
          operation_id: nil,
          error_class: "RuntimeError",
          error_message: "perform exploded",
        )
        expect(attempt.error_backtrace).to be_present
      end

      it "persists the attempt even though the Operation row was rolled back" do
        before_ops = Operation.count

        expect {
          raising_class.new(a: 1).call(transaction: true)
        }.to raise_error(RuntimeError)

        expect(Operation.count).to eq(before_ops) # rolled back
        expect(OperationAttempt.last.status).to eq("failed")
      end

      it "captures the failure even when validation fails inside runtime_check" do
        precheck_class = Class.new(BaseOperation) do
          inputs :a
          def runtime_check
            errors.add(:base, "no good")
          end
          def perform(_); end
        end
        stub_const("Stern::PrecheckOp", precheck_class)

        expect {
          precheck_class.new(a: 1).call(transaction: false)
        }.to raise_error(ArgumentError, /no good/)

        attempt = OperationAttempt.last
        expect(attempt.status).to eq("failed")
        expect(attempt.error_class).to eq("ArgumentError")
      end
    end

    describe "input-validation rejection (pre-flight)" do
      # Validation failures happen before any work is attempted, so they
      # don't produce an OperationAttempt row — those are caller errors.
      it "does not record an attempt when invalid? raises ArgumentError" do
        validating_class = Class.new(BaseOperation) do
          inputs :a
          validates :a, presence: true
          def perform(_); end
        end
        stub_const("Stern::ValidatingOp", validating_class)

        expect {
          validating_class.new(a: nil).call(transaction: false)
        }.to raise_error(ArgumentError)
        expect(OperationAttempt.where(name: "ValidatingOp")).to be_empty
      end
    end

    describe "idempotent replay" do
      let(:key) { "att-test-#{SecureRandom.hex(4)}" }

      # find_existing_operation hits before any attempt is recorded — replays
      # are not "attempts at fresh work," they're cache hits. Skip them.
      it "does not record an attempt on a same-params replay" do
        test_class.new(a: 1, b: 2).call(transaction: false, idem_key: key)
        before_count = OperationAttempt.count

        replay = test_class.new(a: 1, b: 2)
        replay.call(transaction: false, idem_key: key)

        expect(OperationAttempt.count).to eq(before_count) # replay was a cache hit
      end
    end
  end
end
