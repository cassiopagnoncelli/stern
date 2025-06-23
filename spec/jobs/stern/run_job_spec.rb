require 'rails_helper'

module Stern
  RSpec.describe RunJob, type: :job do
    subject(:job) { described_class.new }

    describe '#perform' do
      let(:sop_ids) { [1, 2, 3] }

      before do
        allow(ScheduledOperationService).to receive(:list).and_return(sop_ids)
        allow(ScheduledOperationService).to receive(:process_sop)
      end

      it 'calls ScheduledOperationService.list to get scheduled operation IDs' do
        job.perform

        expect(ScheduledOperationService).to have_received(:list)
      end

      it 'processes each scheduled operation ID' do
        job.perform

        sop_ids.each do |sop_id|
          expect(ScheduledOperationService).to have_received(:process_sop).with(sop_id)
        end
      end

      context 'when no scheduled operations exist' do
        let(:sop_ids) { [] }

        it 'does not call process_sop' do
          job.perform

          expect(ScheduledOperationService).not_to have_received(:process_sop)
        end
      end

      context 'when ScheduledOperationService.process_sop raises an error' do
        before do
          allow(ScheduledOperationService).to receive(:process_sop).with(1).and_raise(StandardError, 'Processing failed')
        end

        it 'allows the error to propagate' do
          expect { job.perform }.to raise_error(StandardError, 'Processing failed')
        end
      end
    end
  end
end
