require "rails_helper"

module Stern
  RSpec.describe SopService, type: :service do
    subject(:service) { described_class }

    let(:scheduled_op) { ScheduledOperation.build(name:, params:, after_time:) }
    let(:name) { "PayPix" }
    let(:params) { { payment_id: 123, merchant_id: 1101, amount: 9900, fee: 65 } }
    let(:after_time) { described_class::QUEUE_ITEM_TIMEOUT_IN_SECONDS.seconds.ago.utc }

    describe ".enqueue_list" do
      before { scheduled_op.save! }

      it "picks a list of ScheduledOperation marking items picked" do
        expect(service.enqueue_list).to contain_exactly(scheduled_op.id)
        expect(scheduled_op.reload.status).to eq("picked")
      end
    end

    describe ".clear_picked" do
      before do
        scheduled_op.save!
        service.enqueue_list
        scheduled_op.update!(status_time: after_time)
      end

      it "changes status from picked to pending" do
        expect {
          service.clear_picked
        }.to change {
          scheduled_op.reload.status
        }.from("picked").to("pending")
      end
    end
  end
end
