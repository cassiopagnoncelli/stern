require 'rails_helper'

module Stern
  RSpec.describe Operation, type: :model do
    subject(:operation) { create :operation }

    it { should validate_presence_of(:operation_def_id) }
    it { should validate_presence_of(:direction) }
    it { should have_many(:txs) }
  end
end
