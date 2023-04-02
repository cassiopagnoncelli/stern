# frozen_string_literal: true

module Stern
  class MerchantBalancesQuery < BaseQuery
    def call(**params)
      "Returning call #{params.inspect}"
    end
  end
end
