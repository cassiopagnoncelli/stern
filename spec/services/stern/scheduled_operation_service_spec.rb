require "rails_helper"

module Stern # rubocop:disable Metrics/ModuleLength
  RSpec.describe ScheduledOperationService, type: :service do
    subject(:service) { described_class }

    let(:scheduled_op) { ScheduledOperation.build(name:, params:, after_time:) }
    let(:name) { "PayPix" }
    let(:params) { { payment_id: 123, merchant_id: 1101, amount: 9900, fee: 65 } }
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

    describe ".process_sop" do
      context "when scheduled operation not found" do
        it "raises ArgumentError" do
          expect { service.process_sop(999_999) }.to raise_error(ActiveRecord::RecordNotFound)
        end
      end

      context "when not picked" do
        [:pending, :in_progress, :finished, :canceled, :argument_error, :runtime_error]
          .each do |status|
          it "raises CannotProcessNonPickedSopError when status is #{status}" do
            scheduled_op.status = status
            scheduled_op.save!
            expect { service.process_sop(scheduled_op.id) }.to raise_error(
              service::CannotProcessNonPickedSopError,
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
            service::CannotProcessAheadOfTimeError
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
            an_instance_of(::Stern::PayPix),
            scheduled_op
          )
        end

        it "creates the operation with symbolized params" do
          allow(::Stern::PayPix).to receive(:new).and_call_original
          service.process_sop(scheduled_op.id)
          expect(::Stern::PayPix).to have_received(:new).with(
            payment_id: 123,
            merchant_id: 1101,
            amount: 9900,
            fee: 65
          )
        end
      end
    end

    describe ".process_operation" do
      let(:operation) do
        op_klass = Object.const_get("Stern::#{scheduled_op.name}")
        op_klass.new(**scheduled_op.params.symbolize_keys)
      end

      context "when not in progress" do
        [:pending, :picked, :finished, :canceled, :runtime_error]
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

        context "when operation raises StandardError" do
          before do
            allow(operation).to receive(:call).and_raise(StandardError, "runtime error")
          end

          it "sets status to runtime_error" do
            expect { service.process_operation(operation, scheduled_op) }.to change {
              scheduled_op.reload.status
            }.from("in_progress").to("runtime_error")
          end

          it "sets error_message" do
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.error_message).to eq("runtime error")
          end

          it "updates status_time" do
            service.process_operation(operation, scheduled_op)
            expect(scheduled_op.reload.status_time).to be_within(1.second).of(Time.current.utc)
          end
        end
      end
    end

    # Cleanup
    after { ScheduledOperation.destroy_all }
  end
end
