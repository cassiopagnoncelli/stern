require "rails_helper"
require "rake"

RSpec.describe "stern rake tasks", type: :task do
  before(:all) do
    Rake.application.rake_require("tasks/stern_tasks", [Stern::Engine.root.join("lib").to_s])
    Rake::Task.define_task(:environment)
  end

  describe "stern:sop:rescue" do
    let(:task) { Rake::Task["stern:sop:rescue"] }

    after { task.reenable }

    it "calls #rescue! on the targeted SOP" do
      sop = create(
        :scheduled_operation,
        status: :runtime_error,
        retry_count: 5,
        error_message: "boom",
      )

      task.invoke(sop.id.to_s)

      sop.reload
      expect(sop.status).to eq("pending")
      expect(sop.retry_count).to eq(0)
      expect(sop.error_message).to be_nil
    end

    it "raises when the SOP is not :runtime_error" do
      sop = create(:scheduled_operation, status: :finished)
      expect { task.invoke(sop.id.to_s) }.to raise_error(ArgumentError, /runtime_error/)
    end
  end

  describe "stern:sop:rescue_all" do
    let(:task) { Rake::Task["stern:sop:rescue_all"] }

    after { task.reenable }

    it "rescues only the SOPs whose name matches the argument" do
      target_a = create(:scheduled_operation, name: "ChargePix", status: :runtime_error,
                        retry_count: 5, error_message: "boom")
      target_b = create(:scheduled_operation, name: "ChargePix", status: :runtime_error,
                        retry_count: 5, error_message: "boom")
      other_op = create(:scheduled_operation, name: "RefundPix", status: :runtime_error,
                        retry_count: 5, error_message: "boom")

      task.invoke("ChargePix")

      expect(target_a.reload.status).to eq("pending")
      expect(target_b.reload.status).to eq("pending")
      expect(other_op.reload.status).to eq("runtime_error")
    end

    it "skips :runtime_error SOPs whose name does not match" do
      ignored = create(:scheduled_operation, name: "ChargePix", status: :runtime_error,
                       retry_count: 5, error_message: "boom")

      task.invoke("OtherOp")

      expect(ignored.reload.status).to eq("runtime_error")
    end

    it "raises ArgumentError when name is blank" do
      expect { task.invoke("") }.to raise_error(ArgumentError, /name required/)
    end
  end
end
