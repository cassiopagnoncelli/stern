require 'rails_helper'

module Stern
  RSpec.describe OperationDef, type: :model do
    subject(:operation_def) { create :operation_def }

    it { should validate_presence_of(:active) }
    it { should validate_presence_of(:undo_capability) }

    it { should have_many(:operations) }
  end
end
