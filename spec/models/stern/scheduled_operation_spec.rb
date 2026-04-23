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

      it "transitions :runtime_error → :pending and resets retry state" do
        sop.rescue!
        sop.reload

        expect(sop.status).to eq("pending")
        expect(sop.retry_count).to eq(0)
        expect(sop.error_message).to be_nil
        expect(sop.after_time).to be_within(2.seconds).of(Time.current)
        expect(sop.status_time).to be_within(2.seconds).of(Time.current)
      end

      it "instruments stern.sop.rescued" do
        events = []
        subscription = ActiveSupport::Notifications.subscribe("stern.sop.rescued") do |*args|
          events << ActiveSupport::Notifications::Event.new(*args)
        end

        sop.rescue!

        ActiveSupport::Notifications.unsubscribe(subscription)
        expect(events.size).to eq(1)
        expect(events.first.payload).to include(id: sop.id, op_name: sop.name)
      end

      %i[pending picked in_progress finished canceled argument_error].each do |bad_status|
        it "raises ArgumentError when status is :#{bad_status}" do
          bad_sop = create(:scheduled_operation, status: bad_status, retry_count: 2, error_message: "x")
          expect { bad_sop.rescue! }.to raise_error(ArgumentError, /rescue!.*runtime_error/)
          expect(bad_sop.reload.retry_count).to eq(2)
          expect(bad_sop.error_message).to eq("x")
        end
      end
    end
  end
end
