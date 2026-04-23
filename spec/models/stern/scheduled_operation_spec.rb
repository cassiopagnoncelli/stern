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
  end
end
