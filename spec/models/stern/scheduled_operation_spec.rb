require 'rails_helper'

module Stern
  RSpec.describe ScheduledOperation, type: :model do
    subject(:scheduled_operation) { create :scheduled_operation }

    let(:name) { 'PayPix' }
    let(:status) { :pending }

    describe "validations" do
      it { should validate_presence_of(:operation_def_id) }
      it { should validate_presence_of(:after_time) }
      it { should validate_presence_of(:status) }
      it { should validate_presence_of(:status_time) }
      it { should belong_to(:operation_def).class_name('Stern::OperationDef').optional }
      it { should define_enum_for(:status) }
    end
    
    describe "#build" do
      subject(:build) { described_class.build(name:, params:, after_time:, status:, status_time:) }

      let(:params) { scheduled_operation.params }
      let(:after_time) { scheduled_operation.after_time }
      let(:status_time) { scheduled_operation.status_time }

      it { is_expected.to be_an_instance_of described_class }
    end
  end
end
