# frozen_string_literal: true

module Stern
  class BaseQuery
    def call(**params)
      raise NotImplementedError
    end

    def sql
      raise NotImplementedError
    end
  end
end
