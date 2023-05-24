require 'rails_helper'

module Stern
  RSpec.describe Operation, type: :model do
    subject(:operation) { create :operation }

    it { should allow_value('PayPix').for(:name) }
    it { should allow_value('PayBoletoV1').for(:name) }
    it { should validate_presence_of(:direction) }
    it { should have_many(:txs) }
  end
end
