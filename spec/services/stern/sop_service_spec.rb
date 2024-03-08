require "rails_helper"

module Stern # rubocop:disable Metrics/ModuleLength
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
        expect { service.clear_picked }.to change {
          scheduled_op.reload.status
        }.from("picked").to("pending")
      end
    end

    describe ".preprocess_sop" do
      context "when non picked" do
        [:pending, :in_progress, :finished, :canceled, :argument_error, :runtime_error]
          .each do |status|
          it "raises CannotProcessNonPickedSopError when status is #{status}" do
            sop = ScheduledOperation.build(name:, status:, params:, after_time:)
            sop.save!
            expect { service.preprocess_sop(sop.id) }.to raise_error(
              service::CannotProcessNonPickedSopError,
            )
          end
        end

        after { ScheduledOperation.destroy_all }
      end

      context "when picked" do
        before do
          scheduled_op.status = :picked
          scheduled_op.save!
          allow(service).to receive(:process_sop).and_return(true)
        end

        it "handles picked sops" do
          expect { service.preprocess_sop(scheduled_op.id) }.not_to raise_error
          expect(service).to have_received(:process_sop)
        end
      end
    end

    describe ".process_sop" do
      context "when non-picked" do
        [:pending, :in_progress, :finished, :canceled, :argument_error, :runtime_error]
          .each do |status|
          it "raises CannotProcessNonPickedSopError when status is #{status}" do
            sop = ScheduledOperation.build(name:, status:, params:, after_time:)
            sop.save!
            expect { service.process_sop(sop) }.to raise_error(
              service::CannotProcessNonPickedSopError,
            )
          end
        end

        after { ScheduledOperation.destroy_all }
      end

      context "when picked" do
        before do
          scheduled_op.status = :picked
          scheduled_op.after_time = after_time
          scheduled_op.save!
          allow(service).to receive(:process_operation).and_return(true)
        end

        it "raises error before after_time" do
          scheduled_op.update!(after_time: 1.minute.from_now)
          expect {
            service.process_sop(scheduled_op)
          }.to raise_error(service::CannotProcessAheadOfTimeError)
        end

        it "changes status to in_progress" do
          expect {
            service.process_sop(scheduled_op)
          }.to change {
            scheduled_op.reload.status
          }.from("picked").to("in_progress")
        end

        it "calls process_operation" do
          service.process_sop(scheduled_op)
          expect(service).to have_received(:process_operation).with(anything, scheduled_op)
        end
      end
    end

    describe ".process_operation" do
      let(:operation) do
        op_klass = Object.const_get("Stern::#{scheduled_op.name}")
        op_klass.new(**scheduled_op.params.symbolize_keys)
      end

      context "when in progress" do
        before do
          scheduled_op.status = :in_progress
          scheduled_op.save!
        end

        it "persists operation" do
          service.process_operation(operation, scheduled_op)
          expect(operation.operation).to be_persisted
        end

        it "finalises sop" do
          service.process_operation(operation, scheduled_op)
          expect(scheduled_op.reload.status).to eq("finished")
        end
      end

      context "when not in progress" do
        [:pending, :picked, :finished, :canceled, :argument_error, :runtime_error]
          .each do |status|
          it "marks error when status is #{status}" do
            scheduled_op.status = status
            scheduled_op.save!
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.error_message).to eq("sop not in progress")
          end
        end
      end
    end
  end
end
