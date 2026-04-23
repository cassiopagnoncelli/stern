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

    describe "DEFAULT_RETRY_POLICY constant" do
      it "is frozen" do
        expect(described_class::DEFAULT_RETRY_POLICY).to be_frozen
      end

      it "has the documented shape and values" do
        expect(described_class::DEFAULT_RETRY_POLICY).to eq(
          max_retries: 5, backoff: :exponential, base: 30,
        )
      end
    end

    describe "SUPPORTED_BACKOFF_STRATEGIES constant" do
      it "is frozen" do
        expect(described_class::SUPPORTED_BACKOFF_STRATEGIES).to be_frozen
      end

      it "lists exactly :exponential and :constant" do
        expect(described_class::SUPPORTED_BACKOFF_STRATEGIES).to contain_exactly(:exponential, :constant)
      end
    end

    describe ".resolved_retry_policy (no DSL call)" do
      it "returns DEFAULT_RETRY_POLICY by reference (no copy) when never declared" do
        klass = Class.new(described_class) { inputs :x }
        expect(klass.resolved_retry_policy).to equal(described_class::DEFAULT_RETRY_POLICY)
      end

      it "returns the same value across many calls" do
        klass = Class.new(described_class) { inputs :x }
        expect(klass.resolved_retry_policy).to eq(klass.resolved_retry_policy)
      end
    end

    describe ".retry_policy" do
      describe "merge behavior" do
        it "merges all three declared overrides on top of the defaults" do
          klass = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 1, backoff: :constant, base: 60
          end
          expect(klass.resolved_retry_policy).to eq(
            max_retries: 1, backoff: :constant, base: 60,
          )
        end

        it "leaves unspecified keys at their defaults" do
          klass = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 2
          end
          expect(klass.resolved_retry_policy).to eq(
            max_retries: 2,
            backoff: described_class::DEFAULT_RETRY_POLICY[:backoff],
            base: described_class::DEFAULT_RETRY_POLICY[:base],
          )
        end

        it "treats explicit nil as 'use the default' (compact drops it)" do
          klass = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 7, base: nil
          end
          expect(klass.resolved_retry_policy[:base]).to eq(described_class::DEFAULT_RETRY_POLICY[:base])
        end

        it "is callable with no kwargs (resets to a defaults-equivalent hash)" do
          klass = Class.new(described_class) do
            inputs :x
            retry_policy
          end
          expect(klass.resolved_retry_policy).to eq(described_class::DEFAULT_RETRY_POLICY)
        end

        it "does not mutate DEFAULT_RETRY_POLICY when overrides are applied" do
          before_snapshot = described_class::DEFAULT_RETRY_POLICY.dup
          Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 99, backoff: :constant, base: 999
          end
          expect(described_class::DEFAULT_RETRY_POLICY).to eq(before_snapshot)
        end
      end

      describe "re-declaration" do
        it "lets the most recent retry_policy call win" do
          klass = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 1
            retry_policy max_retries: 9
          end
          expect(klass.resolved_retry_policy[:max_retries]).to eq(9)
        end

        it "treats each retry_policy call as a fresh merge against DEFAULT_RETRY_POLICY (does NOT accumulate)" do
          # First call sets backoff: :constant; second call only changes
          # max_retries — backoff should snap back to the default :exponential.
          klass = Class.new(described_class) do
            inputs :x
            retry_policy backoff: :constant, base: 90
            retry_policy max_retries: 2
          end
          expect(klass.resolved_retry_policy).to eq(
            max_retries: 2,
            backoff: :exponential,
            base: described_class::DEFAULT_RETRY_POLICY[:base],
          )
        end
      end

      describe "subclass isolation" do
        it "isolates the policy per subclass when each declares its own" do
          a = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 1
          end
          b = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 9
          end
          expect(a.resolved_retry_policy[:max_retries]).to eq(1)
          expect(b.resolved_retry_policy[:max_retries]).to eq(9)
        end

        it "leaves siblings without a policy at the defaults" do
          a = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 1
          end
          b = Class.new(described_class) { inputs :x }
          expect(b.resolved_retry_policy).to eq(described_class::DEFAULT_RETRY_POLICY)
          expect(a.resolved_retry_policy[:max_retries]).to eq(1)
        end

        # Documents intentional design: retry_policy uses a class instance
        # variable (matching the `inputs` DSL pattern) and is therefore NOT
        # inherited by subclasses-of-subclasses. If a deeper subclass needs
        # the parent's policy it must re-declare it. Switch to
        # `class_attribute` to change this.
        it "does NOT inherit the policy from a parent BaseOperation subclass" do
          parent = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 1, backoff: :constant, base: 60
          end
          child = Class.new(parent)
          expect(child.resolved_retry_policy).to eq(described_class::DEFAULT_RETRY_POLICY)
        end
      end

      describe "validation" do
        it "rejects backoff: :linear with a clear message" do
          expect {
            Class.new(described_class) do
              inputs :x
              retry_policy backoff: :linear
            end
          }.to raise_error(ArgumentError, /unknown backoff strategy.*:linear/)
        end

        it "rejects an unknown backoff regardless of other valid kwargs" do
          expect {
            Class.new(described_class) do
              inputs :x
              retry_policy max_retries: 1, backoff: :bogus, base: 30
            end
          }.to raise_error(ArgumentError, /unknown backoff strategy/)
        end

        it "rejects backoff strings ('exponential' instead of :exponential)" do
          expect {
            Class.new(described_class) do
              inputs :x
              retry_policy backoff: "exponential"
            end
          }.to raise_error(ArgumentError, /unknown backoff strategy/)
        end

        it "lists the supported strategies in the error message" do
          expect {
            Class.new(described_class) do
              inputs :x
              retry_policy backoff: :linear
            end
          }.to raise_error(ArgumentError, /exponential.*constant|constant.*exponential/)
        end

        it "leaves the prior policy untouched when a bad re-declaration raises" do
          klass = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 2, backoff: :constant, base: 60
          end
          expect {
            klass.retry_policy(backoff: :linear)
          }.to raise_error(ArgumentError)
          expect(klass.resolved_retry_policy).to eq(
            max_retries: 2, backoff: :constant, base: 60,
          )
        end

        it "accepts both supported strategies symmetrically" do
          %i[exponential constant].each do |strategy|
            klass = Class.new(described_class) do
              inputs :x
              retry_policy backoff: strategy
            end
            expect(klass.resolved_retry_policy[:backoff]).to eq(strategy)
          end
        end
      end

      describe "boundary values (current behavior — no input validation)" do
        # These document that retry_policy currently passes numeric values
        # through without sanity-checking them. If validation tightens, these
        # specs become a contract change to discuss.
        it "accepts max_retries: 0 (terminal-on-first-failure)" do
          klass = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 0
          end
          expect(klass.resolved_retry_policy[:max_retries]).to eq(0)
        end

        it "accepts a very large max_retries" do
          klass = Class.new(described_class) do
            inputs :x
            retry_policy max_retries: 1_000_000
          end
          expect(klass.resolved_retry_policy[:max_retries]).to eq(1_000_000)
        end

        it "accepts a fractional base" do
          klass = Class.new(described_class) do
            inputs :x
            retry_policy base: 0.5
          end
          expect(klass.resolved_retry_policy[:base]).to eq(0.5)
        end
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

      context "with a :currency input" do
        let(:klass) { Class.new(described_class) { inputs :currency } }

        it "coerces a currency string to its integer code" do
          expect(klass.new(currency: "BRL").currency).to eq(::Stern.cur("BRL"))
        end

        it "is case- and whitespace-insensitive" do
          expect(klass.new(currency: " usd ").currency).to eq(::Stern.cur("USD"))
        end

        it "passes integer codes through untouched" do
          code = ::Stern.cur("BRL")
          expect(klass.new(currency: code).currency).to eq(code)
        end

        it "leaves nil currency as nil" do
          expect(klass.new(currency: nil).currency).to be_nil
        end

        it "raises on an unknown currency" do
          expect { klass.new(currency: "ZZZ") }.to raise_error(UnknownCurrencyError)
        end

        it "runs before the subclass normalize_inputs hook" do
          subclass = Class.new(described_class) do
            inputs :currency
            attr_reader :currency_seen_by_hook
            def normalize_inputs
              @currency_seen_by_hook = currency
            end
          end
          op = subclass.new(currency: "BRL")
          expect(op.currency_seen_by_hook).to eq(::Stern.cur("BRL"))
        end
      end

      context "without a :currency input" do
        it "does not touch an attribute that happens to be named currency" do
          klass = Class.new(described_class) do
            inputs :amount
            attr_accessor :currency
          end
          op = klass.new(amount: 1)
          op.currency = "BRL"
          expect(op.currency).to eq("BRL")
        end
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
