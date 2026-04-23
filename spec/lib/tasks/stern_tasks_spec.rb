require "rails_helper"
require "rake"

RSpec.describe "stern rake tasks", type: :task do
  before(:all) do
    Rake.application.rake_require("tasks/stern_tasks", [ Stern::Engine.root.join("lib").to_s ])
    Rake::Task.define_task(:environment)
  end

  describe "stern:sop:rescue" do
    let(:task) { Rake::Task["stern:sop:rescue"] }

    after { task.reenable }

    describe "happy path" do
      let!(:sop) do
        create(:scheduled_operation,
               status: :runtime_error, retry_count: 5, error_message: "boom")
      end

      it "transitions the SOP to :pending" do
        expect { task.invoke(sop.id.to_s) }.to change { sop.reload.status }
          .from("runtime_error").to("pending")
      end

      it "resets retry_count to 0" do
        expect { task.invoke(sop.id.to_s) }.to change { sop.reload.retry_count }.from(5).to(0)
      end

      it "clears error_message" do
        expect { task.invoke(sop.id.to_s) }.to change { sop.reload.error_message }.to(nil)
      end

      it "logs the rescue with id and name" do
        expect(Rails.logger).to receive(:info).with(/stern:sop:rescue.*id=#{sop.id}.*name=ChargePix/)
        task.invoke(sop.id.to_s)
      end

      it "accepts the id as an integer-typed string and finds the SOP" do
        expect { task.invoke(sop.id.to_s) }.not_to raise_error
      end
    end

    describe "argument handling" do
      it "raises RecordNotFound when the id does not exist" do
        expect { task.invoke("999999999") }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "raises KeyError when no id is supplied" do
        expect { task.invoke }.to raise_error(KeyError, /id/)
      end
    end

    describe "state guard (delegated to #rescue!)" do
      %i[pending picked in_progress finished canceled argument_error].each do |bad_status|
        it "raises ArgumentError when the SOP is :#{bad_status}" do
          sop = create(:scheduled_operation, status: bad_status)
          expect { task.invoke(sop.id.to_s) }.to raise_error(ArgumentError, /runtime_error/)
        end
      end
    end
  end

  describe "stern:sop:rescue_all" do
    let(:task) { Rake::Task["stern:sop:rescue_all"] }

    after { task.reenable }

    describe "filtered bulk recovery" do
      let!(:target_a) do
        create(:scheduled_operation,
               name: "ChargePix", status: :runtime_error, retry_count: 5, error_message: "boom")
      end
      let!(:target_b) do
        create(:scheduled_operation,
               name: "ChargePix", status: :runtime_error, retry_count: 3, error_message: "boom")
      end
      let!(:other_op) do
        create(:scheduled_operation,
               name: "RefundPix", status: :runtime_error, retry_count: 2, error_message: "x")
      end

      it "rescues every :runtime_error SOP whose name matches" do
        task.invoke("ChargePix")
        expect(target_a.reload.status).to eq("pending")
        expect(target_b.reload.status).to eq("pending")
      end

      it "leaves SOPs of other names alone" do
        task.invoke("ChargePix")
        expect(other_op.reload.status).to eq("runtime_error")
        expect(other_op.error_message).to eq("x")
      end

      it "logs the count of rescued SOPs" do
        expect(Rails.logger).to receive(:info).with(/stern:sop:rescue_all.*count=2.*name=ChargePix/)
        task.invoke("ChargePix")
      end
    end

    describe "non-matching scope" do
      it "does not touch :runtime_error SOPs whose name differs" do
        ignored = create(:scheduled_operation,
                         name: "ChargePix", status: :runtime_error, retry_count: 5)
        task.invoke("OtherOp")
        expect(ignored.reload.status).to eq("runtime_error")
      end

      it "skips non-:runtime_error SOPs even when the name matches" do
        %i[pending picked in_progress finished canceled argument_error].each do |status|
          sop = create(:scheduled_operation, name: "ChargePix", status: status, retry_count: 1)
          before_attrs = sop.attributes
          task.invoke("ChargePix")
          task.reenable
          expect(sop.reload.attributes.except("updated_at")).to eq(before_attrs.except("updated_at"))
        end
      end

      it "logs count=0 when nothing matches the filter" do
        expect(Rails.logger).to receive(:info).with(/count=0/)
        task.invoke("DefinitelyMissing")
      end

      it "runs cleanly with an empty database" do
        expect { task.invoke("ChargePix") }.not_to raise_error
      end
    end

    describe "argument handling" do
      it "raises ArgumentError when name is the empty string" do
        expect { task.invoke("") }.to raise_error(ArgumentError, /name required/)
      end

      it "raises ArgumentError when name is whitespace only" do
        expect { task.invoke("   ") }.to raise_error(ArgumentError, /name required/)
      end

      it "raises ArgumentError when no name is supplied" do
        expect { task.invoke }.to raise_error(ArgumentError, /name required/)
      end
    end

    describe "batching" do
      it "rescues many SOPs without truncation (find_each)" do
        25.times do
          create(:scheduled_operation,
                 name: "ChargePix", status: :runtime_error, retry_count: 5, error_message: "boom")
        end
        task.invoke("ChargePix")
        expect(::Stern::ScheduledOperation.runtime_error.where(name: "ChargePix").count).to eq(0)
      end
    end
  end
end
