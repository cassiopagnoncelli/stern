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

    describe "#build" do
      subject(:build) { described_class.build(name:, params:, after_time:, status:, status_time:) }
      let(:name) { "PayPix" }
      let(:params) { scheduled_operation.params }
      let(:after_time) { scheduled_operation.after_time }
      let(:status) { :pending }
      let(:status_time) { scheduled_operation.status_time }
      let(:scheduled_operation) { create(:scheduled_operation) }

      it { should be_an_instance_of described_class }
    end
  end
end
