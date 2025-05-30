require "rails_helper"

module Stern
  RSpec.describe Operation, type: :model do
    subject(:operation) { create :operation }

    it { should validate_presence_of(:name) }
    it { should validate_presence_of(:direction) }
    it { should have_many(:entry_pairs) }
  end
end
