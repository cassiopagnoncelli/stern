require "rails_helper"

module Stern
  RSpec.describe AppendOnly do
    # Minimal AR class that includes the concern, backed by the simple stern_books table.
    # Overriding `.name` keeps the demodulized error message stable regardless of the anonymous
    # class id that Rails assigns to `Class.new(...)`.
    let(:test_class) do
      klass = Class.new(ApplicationRecord) do
        self.table_name = "stern_books"
        include AppendOnly
      end
      klass.define_singleton_method(:name) { "Stern::AppendOnlyTestRecord" }
      klass
    end

    let(:probe_id) { 2_100_000_000 }

    before { ApplicationRecord.connection.execute("DELETE FROM stern_books WHERE id = #{probe_id}") }
    after  { ApplicationRecord.connection.execute("DELETE FROM stern_books WHERE id = #{probe_id}") }

    describe ".update_message" do
      it "formats with the demodulized class name" do
        klass = double(name: "Stern::Foo")
        expect(described_class.update_message(klass)).to eq("Foo records cannot be updated by design")
      end

      it "handles top-level class names" do
        klass = double(name: "Bar")
        expect(described_class.update_message(klass)).to eq("Bar records cannot be updated by design")
      end
    end

    describe "class-level overrides" do
      it ".create raises NotImplementedError directing the caller to create!" do
        expect { test_class.create(id: probe_id, name: "anything") }
          .to raise_error(NotImplementedError, "Use create! instead")
      end

      it ".update_all raises with the record-type message" do
        expect { test_class.update_all(name: "x") }
          .to raise_error(NotImplementedError, "AppendOnlyTestRecord records cannot be updated by design")
      end

      it ".destroy_all raises directing the caller to delete_all" do
        expect { test_class.destroy_all }
          .to raise_error(NotImplementedError, /Ledger is append-only.*use delete_all/)
      end
    end

    describe "instance-level overrides" do
      let(:instance) { test_class.create!(id: probe_id, name: "probe") }

      it "#update raises with the record-type message" do
        expect { instance.update(name: "x") }
          .to raise_error(NotImplementedError, "AppendOnlyTestRecord records cannot be updated by design")
      end

      it "#update! raises with the record-type message" do
        expect { instance.update!(name: "x") }
          .to raise_error(NotImplementedError, "AppendOnlyTestRecord records cannot be updated by design")
      end

      it "#destroy raises directing the caller to destroy!" do
        expect { instance.destroy }
          .to raise_error(NotImplementedError, "Use destroy! instead")
      end
    end

    describe "before_update callback" do
      let(:instance) { test_class.create!(id: probe_id, name: "probe") }

      it "raises when save would persist a change, not only when calling update*" do
        instance.assign_attributes(name: "changed")
        expect { instance.save }
          .to raise_error(NotImplementedError, "AppendOnlyTestRecord records cannot be updated by design")
      end
    end

    describe "allowed paths" do
      it ".create! still persists a new record" do
        expect { test_class.create!(id: probe_id, name: "ok") }
          .to change { test_class.where(id: probe_id).count }.from(0).to(1)
      end

      it "reads do not raise (the concern only blocks writes)" do
        test_class.create!(id: probe_id, name: "readable")
        expect(test_class.find(probe_id).name).to eq("readable")
      end
    end
  end
end
