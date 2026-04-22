require "rails_helper"

module Stern
  RSpec.describe EachUpdate do
    # The concern is currently included in ScheduledOperation; we use it as the live subject.
    describe "when included in a model" do
      it "installs each_update! on the including model's relations" do
        expect(ScheduledOperation.all).to respond_to(:each_update!)
      end

      it "installs each_update on the including model's relations" do
        expect(ScheduledOperation.all).to respond_to(:each_update)
      end
    end

    describe "scoping (does not pollute other models)" do
      it "does not install the methods on a Stern model that does not include it" do
        expect(Book.all).not_to respond_to(:each_update!)
        expect(Entry.all).not_to respond_to(:each_update!)
        expect(EntryPair.all).not_to respond_to(:each_update!)
      end

      it "does not install the methods on ActiveRecord::Relation at large" do
        # Any non-Stern model's relation should not have it either. Using a fresh anonymous
        # model that does not include the concern.
        klass = Class.new(ApplicationRecord) { self.table_name = "stern_books" }
        expect(klass.all).not_to respond_to(:each_update!)
      end
    end

    describe ".each_update!" do
      let(:operation) { create(:operation) }

      before do
        ScheduledOperation.delete_all
        3.times do |i|
          ScheduledOperation.create!(
            name: "ChargePix",
            params: { charge_id: i },
            after_time: 1.minute.ago,
          )
        end
      end

      after { ScheduledOperation.delete_all }

      it "updates every record in the relation through the model callbacks" do
        ScheduledOperation.pending.each_update!(status: :picked)
        expect(ScheduledOperation.pending.count).to eq(0)
        expect(ScheduledOperation.picked.count).to eq(3)
      end
    end
  end
end
