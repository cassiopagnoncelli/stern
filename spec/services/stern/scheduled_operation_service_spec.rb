require "rails_helper"

module Stern # rubocop:disable Metrics/ModuleLength
  RSpec.describe ScheduledOperationService, type: :service do
    subject(:service) { described_class }

    let(:scheduled_op) { ScheduledOperation.build(name:, params:, after_time:) }
    let(:name) { "ChargePix" }
    let(:params) { { charge_id: 1, payment_id: 1101, customer_id: 2, amount: 9900, currency: "usd" } }
    let(:after_time) { described_class::QUEUE_ITEM_TIMEOUT_IN_SECONDS.seconds.ago.utc }

    describe ".list" do
      context "when there are no picked items" do
        before { scheduled_op.save! }

        it "calls enqueue_list and returns the ids" do
          expect(service.list).to contain_exactly(scheduled_op.id)
          expect(scheduled_op.reload.status).to eq("picked")
        end
      end

      context "when there are picked items" do
        before do
          scheduled_op.status = :picked
          scheduled_op.save!
        end

        it "returns the picked items ids" do
          expect(service.list).to contain_exactly(scheduled_op.id)
        end
      end
    end

    describe ".enqueue_list" do
      before { scheduled_op.save! }

      it "picks a list of ScheduledOperation marking items picked" do
        expect(service.enqueue_list).to contain_exactly(scheduled_op.id)
        expect(scheduled_op.reload.status).to eq("picked")
      end

      it "updates status_time" do
        service.enqueue_list
        expect(scheduled_op.reload.status_time).to be_within(1.second).of(Time.current.utc)
      end

      it "only processes pending operations" do
        scheduled_op.status = :finished
        scheduled_op.save!
        expect(service.enqueue_list).to be_empty
      end

      it "only processes operations where after_time has passed" do
        scheduled_op.after_time = 1.minute.from_now
        scheduled_op.save!
        expect(service.enqueue_list).to be_empty
      end

      it "respects the size limit" do
        # Create multiple operations
        3.times do |i|
          ScheduledOperation.create!(
            name: name,
            params: params,
            after_time: after_time,
            status: :pending
          )
        end

        result = service.enqueue_list(2)
        expect(result.size).to eq(2)
      end
    end

    describe ".clear_picked" do
      before do
        scheduled_op.status = :picked
        scheduled_op.status_time = described_class::QUEUE_ITEM_TIMEOUT_IN_SECONDS.seconds.ago.utc - 1.minute
        scheduled_op.save!
      end

      it "changes status from picked to pending for timed out items" do
        expect { service.clear_picked }.to change {
          scheduled_op.reload.status
        }.from("picked").to("pending")
      end

      it "updates status_time" do
        service.clear_picked
        expect(scheduled_op.reload.status_time).to be_within(1.second).of(Time.current.utc)
      end

      it "does not change recently picked items" do
        scheduled_op.update!(status_time: 1.minute.ago.utc)
        expect { service.clear_picked }.not_to change { scheduled_op.reload.status }
      end
    end

    # Rescue for SOPs stuck in `:in_progress`. If a consumer dies mid-op
    # (OOM, SIGKILL, pod eviction), the SOP is left in `:in_progress`
    # forever: `clear_picked` doesn't touch it, and redelivery's retry of
    # `process_sop` trips `CannotProcessNonPickedSopError` and is swallowed.
    # `clear_in_progress` recycles those SOPs: on recovery, it counts the
    # crash as a failed attempt (bumps retry_count, pushes `after_time`
    # forward with the same backoff as the StandardError path) if retries
    # remain; otherwise marks the SOP `:runtime_error` terminally.
    describe ".clear_in_progress" do
      let(:timeout) { described_class::IN_PROGRESS_TIMEOUT_IN_SECONDS }

      before do
        scheduled_op.status = :in_progress
        scheduled_op.status_time = timeout.seconds.ago.utc - 1.minute
        scheduled_op.save!
      end

      context "when retries remain" do
        it "resets status back to pending (retry)" do
          expect { service.clear_in_progress }.to change {
            scheduled_op.reload.status
          }.from("in_progress").to("pending")
        end

        it "increments retry_count" do
          expect { service.clear_in_progress }.to change {
            scheduled_op.reload.retry_count
          }.from(0).to(1)
        end

        it "pushes after_time forward with backoff" do
          service.clear_in_progress
          expect(scheduled_op.reload.after_time).to be_within(2.seconds).of(30.seconds.from_now.utc)
        end

        it "updates status_time" do
          service.clear_in_progress
          expect(scheduled_op.reload.status_time).to be_within(1.second).of(Time.current.utc)
        end

        it "records an error_message explaining the recovery" do
          service.clear_in_progress
          expect(scheduled_op.reload.error_message).to match(/stuck/i)
        end
      end

      context "when retries are exhausted" do
        before { scheduled_op.update!(retry_count: ::Stern::BaseOperation::DEFAULT_RETRY_POLICY[:max_retries]) }

        it "marks the SOP terminally :runtime_error" do
          expect { service.clear_in_progress }.to change {
            scheduled_op.reload.status
          }.from("in_progress").to("runtime_error")
        end

        it "records an error_message" do
          service.clear_in_progress
          expect(scheduled_op.reload.error_message).to match(/stuck/i)
        end
      end

      context "with a per-class retry policy" do
        it "respects a tighter per-class :max_retries (terminal earlier than default)" do
          allow(::Stern::ChargePix).to receive(:resolved_retry_policy).and_return(
            max_retries: 1, backoff: :exponential, base: 30,
          )
          scheduled_op.update!(retry_count: 1)
          expect { service.clear_in_progress }.to change {
            scheduled_op.reload.status
          }.from("in_progress").to("runtime_error")
        end

        it "uses :constant backoff when declared" do
          allow(::Stern::ChargePix).to receive(:resolved_retry_policy).and_return(
            max_retries: 5, backoff: :constant, base: 90,
          )
          scheduled_op.update!(retry_count: 3)
          service.clear_in_progress
          # Constant backoff at retry_count 3 should be 90s, not 30 * 2^3 = 240s.
          expect(scheduled_op.reload.after_time).to be_within(2.seconds).of(90.seconds.from_now.utc)
        end

        it "applies max_retries: 0 (first crash is terminal)" do
          allow(::Stern::ChargePix).to receive(:resolved_retry_policy).and_return(
            max_retries: 0, backoff: :exponential, base: 30,
          )
          scheduled_op.update!(retry_count: 0)
          expect { service.clear_in_progress }.to change {
            scheduled_op.reload.status
          }.from("in_progress").to("runtime_error")
        end

        it "falls back to defaults when sop.name doesn't resolve to a known op class" do
          scheduled_op.update!(name: "GhostOp", retry_count: 0)
          expect { service.clear_in_progress }.to change { scheduled_op.reload.status }.to("pending")
          # Default base 30s exponential at retry_count=0 → 30s.
          expect(scheduled_op.reload.after_time).to be_within(2.seconds).of(30.seconds.from_now.utc)
        end
      end

      it "leaves recently-updated in_progress SOPs alone" do
        scheduled_op.update!(status_time: 1.minute.ago.utc)
        expect { service.clear_in_progress }.not_to change { scheduled_op.reload.status }
      end

      [ :pending, :picked, :finished, :canceled, :argument_error, :runtime_error ].each do |other|
        it "leaves #{other} SOPs alone" do
          scheduled_op.update!(status: other)
          expect { service.clear_in_progress }.not_to change { scheduled_op.reload.status }
        end
      end
    end

    describe ".process_sop" do
      context "when scheduled operation not found" do
        it "raises ArgumentError" do
          expect { service.process_sop(999_999) }.to raise_error(ActiveRecord::RecordNotFound)
        end
      end

      context "when not picked" do
        [ :pending, :in_progress, :finished, :canceled, :argument_error, :runtime_error ]
          .each do |status|
          it "raises CannotProcessNonPickedSopError when status is #{status}" do
            scheduled_op.status = status
            scheduled_op.save!
            expect { service.process_sop(scheduled_op.id) }.to raise_error(
              CannotProcessNonPickedSopError,
            )
          end
        end
      end

      context "when picked but ahead of time" do
        before do
          scheduled_op.status = :picked
          scheduled_op.after_time = 1.minute.from_now
          scheduled_op.save!
        end

        it "raises CannotProcessAheadOfTimeError" do
          expect { service.process_sop(scheduled_op.id) }.to raise_error(
            CannotProcessAheadOfTimeError
          )
        end
      end

      context "when picked and time is due" do
        before do
          scheduled_op.status = :picked
          scheduled_op.after_time = after_time
          scheduled_op.save!
          allow(service).to receive(:process_operation)
        end

        it "changes status to in_progress" do
          expect { service.process_sop(scheduled_op.id) }.to change {
            scheduled_op.reload.status
          }.from("picked").to("in_progress")
        end

        it "updates status_time" do
          service.process_sop(scheduled_op.id)
          expect(scheduled_op.reload.status_time).to be_within(1.second).of(Time.current.utc)
        end

        it "calls process_operation with the operation and scheduled_op" do
          service.process_sop(scheduled_op.id)
          expect(service).to have_received(:process_operation).with(
            an_instance_of(::Stern::ChargePix),
            scheduled_op
          )
        end

        it "creates the operation with symbolized params" do
          allow(::Stern::ChargePix).to receive(:new).and_call_original
          service.process_sop(scheduled_op.id)
          expect(::Stern::ChargePix).to have_received(:new).with(
            charge_id: 1,
            payment_id: 1101,
            customer_id: 2,
            amount: 9900,
            currency: "usd"
          )
        end
      end

      # Defense in depth: even if the SOP ends up being picked and processed
      # more than once (e.g. at-least-once redelivery once a real queue lands,
      # or a clear_picked-then-re-pick flow), the logical operation must not
      # run twice. `BaseOperation#call(idem_key:)` already provides that — it
      # short-circuits with the existing Operation row when one matches — but
      # only if `process_sop` propagates a stable idem_key derived from the
      # SOP id. Without that propagation, the second op.call either duplicates
      # the work or trips a downstream DB unique constraint and bleeds into
      # `:runtime_error`, even though nothing actually failed.
      context "when the same SOP is processed more than once (idempotent retry)" do
        before do
          scheduled_op.status = :picked
          scheduled_op.after_time = after_time
          scheduled_op.save!
        end

        it "propagates a stable idem_key derived from the SOP id to op.call" do
          op_spy = ::Stern::ChargePix.new(**params.symbolize_keys)
          allow(::Stern::ChargePix).to receive(:new).and_return(op_spy)
          allow(op_spy).to receive(:call)

          service.process_sop(scheduled_op.id)

          expected_key = "sop-#{scheduled_op.id.to_s.rjust(8, '0')}"
          expect(op_spy).to have_received(:call).with(idem_key: expected_key)
        end

        it "leaves SOP in :finished (not :runtime_error) on a repeat process_sop" do
          service.process_sop(scheduled_op.id)
          expect(scheduled_op.reload.status).to eq("finished")

          # Simulate a retry: flip status back to :picked (as if clear_picked
          # recycled the row and enqueue_list re-picked it) and call again.
          scheduled_op.reload.update!(status: :picked)

          service.process_sop(scheduled_op.id)
          scheduled_op.reload

          expect(scheduled_op.status).to eq("finished")
          expect(scheduled_op.error_message).to be_blank
        end
      end
    end

    describe ".process_operation" do
      let(:operation) do
        op_klass = Object.const_get("Stern::#{scheduled_op.name}")
        op_klass.new(**scheduled_op.params.symbolize_keys)
      end

      context "when not in progress" do
        [ :pending, :picked, :finished, :canceled, :runtime_error ]
          .each do |status|
          it "sets status to argument_error when status is #{status}" do
            scheduled_op.status = status
            scheduled_op.save!
            expect { service.process_operation(operation, scheduled_op) }.to change {
              scheduled_op.reload.status
            }.to("argument_error")
          end

          it "sets error_message when status is #{status}" do
            scheduled_op.status = status
            scheduled_op.save!
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.error_message).to eq("sop not in progress")
          end
        end

        context "when status is already argument_error" do
          it "keeps status as argument_error" do
            scheduled_op.status = :argument_error
            scheduled_op.save!
            expect { service.process_operation(operation, scheduled_op) }.not_to change {
              scheduled_op.reload.status
            }
          end

          it "sets error_message" do
            scheduled_op.status = :argument_error
            scheduled_op.save!
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.error_message).to eq("sop not in progress")
          end
        end
      end

      context "when in progress" do
        before do
          scheduled_op.status = :in_progress
          scheduled_op.save!
        end

        context "when operation succeeds" do
          before do
            allow(operation).to receive(:call)
          end

          it "calls the operation" do
            service.process_operation(operation, scheduled_op)
            expect(operation).to have_received(:call)
          end

          it "sets status to finished" do
            expect { service.process_operation(operation, scheduled_op) }.to change {
              scheduled_op.reload.status
            }.from("in_progress").to("finished")
          end

          it "updates status_time" do
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.status_time).to be_within(1.second).of(Time.current.utc)
          end
        end

        context "when operation raises ArgumentError" do
          before do
            allow(operation).to receive(:call).and_raise(ArgumentError, "invalid argument")
          end

          it "sets status to argument_error" do
            expect { service.process_operation(operation, scheduled_op) }.to change {
              scheduled_op.reload.status
            }.from("in_progress").to("argument_error")
          end

          it "sets error_message" do
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.error_message).to eq("invalid argument")
          end

          it "updates status_time" do
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.status_time).to be_within(1.second).of(Time.current.utc)
          end
        end

        context "when operation raises StandardError and retries remain" do
          before do
            allow(operation).to receive(:call).and_raise(StandardError, "runtime error")
          end

          it "sets status back to pending (queued for retry, not terminal)" do
            expect { service.process_operation(operation, scheduled_op) }.to change {
              scheduled_op.reload.status
            }.from("in_progress").to("pending")
          end

          it "increments retry_count" do
            expect { service.process_operation(operation, scheduled_op) }.to change {
              scheduled_op.reload.retry_count
            }.from(0).to(1)
          end

          it "pushes after_time forward by the backoff for retry_count 0" do
            service.process_operation(operation, scheduled_op)
            # First retry: 30 * 2**0 = 30 seconds.
            expect(scheduled_op.reload.after_time).to be_within(2.seconds).of(30.seconds.from_now.utc)
          end

          it "sets error_message" do
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.error_message).to eq("runtime error")
          end

          it "updates status_time" do
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.status_time).to be_within(1.second).of(Time.current.utc)
          end

          it "applies exponential backoff on subsequent retries" do
            scheduled_op.update!(retry_count: 3)
            scheduled_op.update!(status: :in_progress)
            service.process_operation(operation, scheduled_op)
            # retry_count=3 → 30 * 2**3 = 240 seconds.
            expect(scheduled_op.reload.after_time).to be_within(2.seconds).of(240.seconds.from_now.utc)
            expect(scheduled_op.reload.retry_count).to eq(4)
          end
        end

        context "when operation raises StandardError and retries are exhausted" do
          before do
            allow(operation).to receive(:call).and_raise(StandardError, "runtime error")
            scheduled_op.update!(retry_count: ::Stern::BaseOperation::DEFAULT_RETRY_POLICY[:max_retries])
            scheduled_op.update!(status: :in_progress)
          end

          it "sets status to runtime_error (terminal)" do
            expect { service.process_operation(operation, scheduled_op) }.to change {
              scheduled_op.reload.status
            }.from("in_progress").to("runtime_error")
          end

          it "does not bump retry_count past the cap" do
            expect { service.process_operation(operation, scheduled_op) }.not_to change {
              scheduled_op.reload.retry_count
            }
          end

          it "sets error_message" do
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.error_message).to eq("runtime error")
          end
        end

        context "when operation succeeds after previous retries" do
          before do
            allow(operation).to receive(:call)
            scheduled_op.update!(retry_count: 2)
            scheduled_op.update!(status: :in_progress)
          end

          it "transitions to finished" do
            expect { service.process_operation(operation, scheduled_op) }.to change {
              scheduled_op.reload.status
            }.from("in_progress").to("finished")
          end

          it "preserves retry_count for observability" do
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.retry_count).to eq(2)
          end
        end

        context "with a per-class retry policy" do
          before { allow(operation).to receive(:call).and_raise(StandardError, "boom") }

          it "respects a tighter per-class :max_retries (terminal earlier than default)" do
            allow(::Stern::ChargePix).to receive(:resolved_retry_policy).and_return(
              max_retries: 1, backoff: :exponential, base: 30,
            )
            scheduled_op.update!(retry_count: 1, status: :in_progress)

            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.status).to eq("runtime_error")
          end

          it "uses :constant backoff when declared" do
            allow(::Stern::ChargePix).to receive(:resolved_retry_policy).and_return(
              max_retries: 5, backoff: :constant, base: 90,
            )
            scheduled_op.update!(retry_count: 3, status: :in_progress)

            service.process_operation(operation, scheduled_op)
            # Constant backoff at retry_count 3 should be 90s, not 30 * 2^3 = 240s.
            expect(scheduled_op.reload.after_time).to be_within(2.seconds).of(90.seconds.from_now.utc)
          end

          it "treats max_retries: 0 as fail-fast (first failure is terminal)" do
            allow(::Stern::ChargePix).to receive(:resolved_retry_policy).and_return(
              max_retries: 0, backoff: :exponential, base: 30,
            )
            scheduled_op.update!(retry_count: 0, status: :in_progress)

            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.status).to eq("runtime_error")
            expect(scheduled_op.retry_count).to eq(0)
          end

          it "retries one more time when retry_count == max_retries - 1" do
            allow(::Stern::ChargePix).to receive(:resolved_retry_policy).and_return(
              max_retries: 3, backoff: :exponential, base: 30,
            )
            scheduled_op.update!(retry_count: 2, status: :in_progress)

            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.status).to eq("pending")
            expect(scheduled_op.retry_count).to eq(3)
          end

          it "is terminal when retry_count == max_retries" do
            allow(::Stern::ChargePix).to receive(:resolved_retry_policy).and_return(
              max_retries: 3, backoff: :exponential, base: 30,
            )
            scheduled_op.update!(retry_count: 3, status: :in_progress)

            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.status).to eq("runtime_error")
          end

          it "is terminal when retry_count exceeds max_retries (state corruption guard)" do
            allow(::Stern::ChargePix).to receive(:resolved_retry_policy).and_return(
              max_retries: 1, backoff: :exponential, base: 30,
            )
            scheduled_op.update!(retry_count: 99, status: :in_progress)

            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.status).to eq("runtime_error")
          end

          it "reads policy from operation.class (NOT via const lookup)" do
            # When the operation instance is passed in, the rescue branch
            # calls `operation.class.resolved_retry_policy` directly — never
            # touches Object.const_get. Prove it by passing a stub op whose
            # class isn't even registered as Stern::*.
            stub_klass = Class.new(::Stern::BaseOperation) do
              inputs :charge_id, :payment_id, :customer_id, :amount, :currency
              retry_policy max_retries: 0
            end
            stub_const("Stern::EphemeralOp", stub_klass)
            ephemeral_op = stub_klass.new(**params.symbolize_keys)
            allow(ephemeral_op).to receive(:call).and_raise(StandardError, "boom")
            scheduled_op.update!(retry_count: 0, status: :in_progress)

            service.process_operation(ephemeral_op, scheduled_op)
            expect(scheduled_op.reload.status).to eq("runtime_error")
          end
        end
      end
    end

    describe ".policy_for (private)" do
      it "returns the op class's resolved_retry_policy when name resolves" do
        sop = ScheduledOperation.new(name: "ChargePix")
        expect(service.send(:policy_for, sop)).to eq(::Stern::ChargePix.resolved_retry_policy)
      end

      it "falls back to BaseOperation::DEFAULT_RETRY_POLICY when name is unknown" do
        sop = ScheduledOperation.new(name: "NoSuchOp")
        expect(service.send(:policy_for, sop)).to eq(::Stern::BaseOperation::DEFAULT_RETRY_POLICY)
      end

      it "falls back to defaults when name is nil" do
        # `Object.const_get("Stern::#{nil}")` interpolates to "Stern::",
        # which raises NameError ("wrong constant name") — caught by the
        # rescue and replaced with DEFAULT_RETRY_POLICY.
        sop = ScheduledOperation.new(name: nil)
        expect(service.send(:policy_for, sop)).to eq(::Stern::BaseOperation::DEFAULT_RETRY_POLICY)
      end

      it "falls back to defaults when name is the empty string" do
        # Object.const_get("Stern::") raises NameError, which IS rescued.
        sop = ScheduledOperation.new(name: "")
        expect(service.send(:policy_for, sop)).to eq(::Stern::BaseOperation::DEFAULT_RETRY_POLICY)
      end

      it "falls back to defaults when name contains namespace separators that miss" do
        sop = ScheduledOperation.new(name: "Nope::Definitely::Missing")
        expect(service.send(:policy_for, sop)).to eq(::Stern::BaseOperation::DEFAULT_RETRY_POLICY)
      end

      it "returns the same hash on consecutive calls (no per-call allocation surprise)" do
        sop = ScheduledOperation.new(name: "ChargePix")
        a = service.send(:policy_for, sop)
        b = service.send(:policy_for, sop)
        expect(a).to eq(b)
      end
    end

    describe ".retry_backoff (private)" do
      it ":exponential at retry_count=0 returns base" do
        policy = { max_retries: 5, backoff: :exponential, base: 30 }
        expect(service.send(:retry_backoff, 0, policy)).to eq(30)
      end

      it ":exponential at retry_count=4 returns base * 2^4" do
        policy = { max_retries: 5, backoff: :exponential, base: 30 }
        expect(service.send(:retry_backoff, 4, policy)).to eq(480)
      end

      it ":exponential matches the documented schedule (30s, 60s, 2m, 4m, 8m)" do
        policy = { max_retries: 5, backoff: :exponential, base: 30 }
        expected = [ 30, 60, 120, 240, 480 ]
        actual = (0..4).map { |rc| service.send(:retry_backoff, rc, policy) }
        expect(actual).to eq(expected)
      end

      it ":constant returns base regardless of retry_count" do
        policy = { max_retries: 5, backoff: :constant, base: 90 }
        expect((0..10).map { |rc| service.send(:retry_backoff, rc, policy) }).to all(eq(90))
      end

      it "raises ArgumentError on an unknown backoff strategy (defense in depth)" do
        policy = { max_retries: 5, backoff: :linear, base: 30 }
        expect { service.send(:retry_backoff, 0, policy) }.to raise_error(ArgumentError, /unknown backoff/)
      end

      it ":exponential with base=0 returns 0 at every retry_count" do
        policy = { max_retries: 5, backoff: :exponential, base: 0 }
        expect(service.send(:retry_backoff, 7, policy)).to eq(0)
      end

      it "rejects a negative retry_count (state-corruption guard)" do
        # retry_count comes from a non-negative integer column in normal use,
        # but a hand-edited row could break that. With :exponential, a
        # negative count would silently produce a fractional backoff that
        # pushes after_time into the past — better to surface the problem.
        policy = { max_retries: 5, backoff: :exponential, base: 30 }
        expect { service.send(:retry_backoff, -1, policy) }
          .to raise_error(ArgumentError, /retry_count.*non-negative/)
      end

      it "rejects a negative retry_count for :constant too" do
        policy = { max_retries: 5, backoff: :constant, base: 30 }
        expect { service.send(:retry_backoff, -5, policy) }
          .to raise_error(ArgumentError, /retry_count.*non-negative/)
      end

      it "accepts retry_count = 0 (the boundary)" do
        policy = { max_retries: 5, backoff: :exponential, base: 30 }
        expect { service.send(:retry_backoff, 0, policy) }.not_to raise_error
      end
    end

    describe "no-policy backward compat (existing ChargePix behavior)" do
      # Belt-and-suspenders: the existing retry/backoff specs above implicitly
      # cover this, but call it out explicitly so a future contributor sees
      # that the default-retry path is the contract preserved by Phase B.
      it "ChargePix without a retry_policy declaration uses DEFAULT_RETRY_POLICY" do
        expect(::Stern::ChargePix.resolved_retry_policy).to eq(::Stern::BaseOperation::DEFAULT_RETRY_POLICY)
      end

      it "policy_for(ChargePix-named SOP) returns DEFAULT_RETRY_POLICY" do
        sop = ScheduledOperation.new(name: "ChargePix")
        expect(service.send(:policy_for, sop)).to eq(::Stern::BaseOperation::DEFAULT_RETRY_POLICY)
      end
    end

    # Cleanup
    after { ScheduledOperation.destroy_all }
  end
end
