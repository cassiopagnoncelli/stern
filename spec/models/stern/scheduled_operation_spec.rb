require "rails_helper"

module Stern
  RSpec.describe ScheduledOperation, type: :model do
    describe "validations" do
      it { should validate_presence_of(:name) }
      it { should validate_presence_of(:after_time) }
      it { should validate_presence_of(:status) }
      it { should validate_presence_of(:status_time) }
      it { should define_enum_for(:status) }
    end

    # The Postgres trigger at db/functions/sop_notify_v01.sql compares
    # `NEW.status = 0` to decide whether to NOTIFY. If `pending` ever moves
    # off 0 in this enum, the trigger silently notifies for the wrong
    # status (or nothing at all). This guard catches the drift.
    describe "enum → SQL trigger integration" do
      it "maps :pending to status integer 0 (required by sop_notify_v01.sql)" do
        expect(described_class.statuses["pending"]).to eq(0)
      end
    end

    describe "#build" do
      subject(:build) { described_class.build(name:, params:, after_time:, status:, status_time:) }
      let(:name) { "ChargePix" }
      let(:params) { scheduled_operation.params }
      let(:after_time) { scheduled_operation.after_time }
      let(:status) { :pending }
      let(:status_time) { scheduled_operation.status_time }
      let(:scheduled_operation) { create(:scheduled_operation) }

      it { should be_an_instance_of described_class }
    end

    describe "#rescue!" do
      let(:sop) do
        create(
          :scheduled_operation,
          status: :runtime_error,
          status_time: 1.hour.ago,
          after_time: 1.hour.ago,
          retry_count: 5,
          error_message: "boom",
        )
      end

      describe "happy path" do
        it "transitions :runtime_error → :pending" do
          expect { sop.rescue! }.to change { sop.reload.status }.from("runtime_error").to("pending")
        end

        it "resets retry_count to 0" do
          expect { sop.rescue! }.to change { sop.reload.retry_count }.from(5).to(0)
        end

        it "clears error_message" do
          expect { sop.rescue! }.to change { sop.reload.error_message }.from("boom").to(nil)
        end

        it "sets after_time to now (immediately due)" do
          sop.rescue!
          expect(sop.reload.after_time).to be_within(2.seconds).of(Time.current)
        end

        it "sets status_time to now" do
          sop.rescue!
          expect(sop.reload.status_time).to be_within(2.seconds).of(Time.current)
        end

        it "preserves name and params untouched" do
          original_name = sop.name
          original_params = sop.params.deep_dup
          sop.rescue!
          expect(sop.reload.name).to eq(original_name)
          expect(sop.params).to eq(original_params)
        end

        it "leaves the SOP in a state that satisfies the picker's pending+due criteria" do
          # Direct predicate check rather than invoking enqueue_list itself,
          # because Postgres NOW() returns the transaction-start timestamp
          # inside use_transactional_fixtures, which beats the SOP's
          # after_time set mid-test and makes the `after_time <= NOW()`
          # clause falsy — a test-transaction artifact, not a real bug.
          sop.rescue!
          sop.reload
          expect(sop.pending?).to be true
          expect(sop.after_time).to be <= Time.current
        end
      end

      describe "instrumentation" do
        let(:events) { [] }
        let!(:subscription) do
          ActiveSupport::Notifications.subscribe("stern.sop.rescued") do |*args|
            events << ActiveSupport::Notifications::Event.new(*args)
          end
        end
        after { ActiveSupport::Notifications.unsubscribe(subscription) }

        it "instruments stern.sop.rescued exactly once" do
          sop.rescue!
          expect(events.size).to eq(1)
        end

        it "carries the SOP id and op_name in the payload" do
          sop.rescue!
          expect(events.first.payload).to eq(id: sop.id, op_name: sop.name)
        end

        it "does NOT instrument when the state guard rejects the call" do
          bad = create(:scheduled_operation, status: :argument_error, retry_count: 1)
          expect { bad.rescue! }.to raise_error(ArgumentError)
          expect(events).to be_empty
        end
      end

      describe "state guard" do
        %i[pending picked in_progress finished canceled argument_error].each do |bad_status|
          context "when status is :#{bad_status}" do
            let(:bad_sop) do
              create(:scheduled_operation, status: bad_status, retry_count: 2, error_message: "x")
            end

            it "raises ArgumentError" do
              expect { bad_sop.rescue! }.to raise_error(ArgumentError, /rescue!.*runtime_error/)
            end

            it "names the offending status in the error message" do
              expect { bad_sop.rescue! }.to raise_error(ArgumentError, /status=#{bad_status}/)
            end

            it "names the SOP id in the error message" do
              expect { bad_sop.rescue! }.to raise_error(ArgumentError, /id=#{bad_sop.id}/)
            end

            it "leaves the SOP completely untouched" do
              expect { bad_sop.rescue! rescue nil }.not_to(change { bad_sop.reload.attributes })
            end
          end
        end
      end

      describe "idempotency / repeated rescue" do
        it "raises ArgumentError on a second rescue! because status is now :pending" do
          sop.rescue!
          expect { sop.rescue! }.to raise_error(ArgumentError, /runtime_error/)
        end

        it "still correctly reports the new status in the second-call error" do
          sop.rescue!
          expect { sop.rescue! }.to raise_error(ArgumentError, /status=pending/)
        end
      end

      describe "boundary states" do
        it "rescues a SOP whose retry_count is 0 (terminal-without-retry case)" do
          sop_no_retries = create(
            :scheduled_operation,
            status: :runtime_error,
            retry_count: 0,
            error_message: "first-fail-terminal",
          )
          sop_no_retries.rescue!
          expect(sop_no_retries.reload).to have_attributes(
            status: "pending",
            retry_count: 0,
            error_message: nil,
          )
        end

        it "rescues a SOP whose error_message is already nil" do
          sop_no_msg = create(:scheduled_operation, status: :runtime_error, retry_count: 3, error_message: nil)
          expect { sop_no_msg.rescue! }.not_to raise_error
          expect(sop_no_msg.reload.status).to eq("pending")
        end
      end
    end
  end
end
