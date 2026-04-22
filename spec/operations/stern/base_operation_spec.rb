require "rails_helper"

module Stern
  RSpec.describe BaseOperation do
    let(:test_class) do
      Class.new(described_class) do
        inputs :a, :b
        attr_reader :perform_calls

        def perform(operation_id)
          @perform_calls ||= []
          @perform_calls << operation_id
        end
      end
    end

    before { stub_const("Stern::TestOp", test_class) }

    describe ".inputs" do
      it "returns the declared input names" do
        expect(test_class.inputs).to eq([ :a, :b ])
      end

      it "generates accessors for each declared input" do
        op = test_class.new(a: 1, b: 2)
        expect(op.a).to eq(1)
        expect(op.b).to eq(2)
        op.a = 99
        expect(op.a).to eq(99)
      end

      it "isolates the input list per subclass" do
        other = Class.new(described_class) { inputs :x }
        expect(test_class.inputs).to eq([ :a, :b ])
        expect(other.inputs).to eq([ :x ])
      end
    end

    describe "#initialize" do
      it "assigns declared inputs from kwargs" do
        op = test_class.new(a: 1, b: 2)
        expect(op.a).to eq(1)
        expect(op.b).to eq(2)
      end

      it "leaves omitted inputs as nil" do
        op = test_class.new(a: 1)
        expect(op.b).to be_nil
      end

      it "raises ArgumentError when given an unknown kwarg" do
        expect { test_class.new(a: 1, bogus: true) }
          .to raise_error(ArgumentError, /unknown inputs.*bogus/)
      end

      it "names the offending class in the error message" do
        expect { test_class.new(bogus: true) }
          .to raise_error(ArgumentError, /Stern::TestOp/)
      end

      it "calls normalize_inputs after assignment" do
        klass = Class.new(described_class) do
          inputs :value
          def normalize_inputs
            self.value = value * 2 if value
          end
        end
        expect(klass.new(value: 5).value).to eq(10)
      end
    end

    describe "#operation_params" do
      it "returns a hash keyed by string input names" do
        op = test_class.new(a: 1, b: 2)
        expect(op.send(:operation_params)).to eq("a" => 1, "b" => 2)
      end

      it "ignores stray instance variables not declared as inputs" do
        op = test_class.new(a: 1, b: 2)
        op.instance_variable_set(:@scratch, "leak me")
        expect(op.send(:operation_params)).to eq("a" => 1, "b" => 2)
      end

      it "reflects values mutated by normalize_inputs" do
        klass = Class.new(described_class) do
          inputs :value
          def normalize_inputs
            self.value = value * 10 if value
          end
        end
        stub_const("Stern::NormalizeOp", klass)
        op = klass.new(value: 3)
        expect(op.send(:operation_params)).to eq("value" => 30)
      end
    end

    describe "#call" do
      let(:op) { test_class.new(a: 1, b: 2) }

      it "persists an Operation record with the demodulized class name and params hash" do
        op.call(transaction: false)
        expect(Operation.last).to have_attributes(
          name: "TestOp",
          params: { "a" => 1, "b" => 2 }
        )
      end

      it "returns the persisted operation id" do
        expect(op.call(transaction: false)).to eq(Operation.last.id)
      end

      it "dispatches to perform with the operation id" do
        op.call(transaction: false)
        expect(op.perform_calls).to eq([ Operation.last.id ])
      end

      context "with idem_key" do
        let(:key) { "test-key-#{SecureRandom.hex(4)}" }

        it "returns the existing operation id without re-running perform when params match" do
          first_id = op.call(transaction: false, idem_key: key)
          replay = test_class.new(a: 1, b: 2)
          expect(replay.call(transaction: false, idem_key: key)).to eq(first_id)
          expect(replay.perform_calls).to be_nil
        end

        it "raises when an operation with that key exists with different params" do
          op.call(transaction: false, idem_key: key)
          mismatched = test_class.new(a: 1, b: 999)
          expect { mismatched.call(transaction: false, idem_key: key) }
            .to raise_error(/different parameters/)
        end
      end
    end
  end
end
