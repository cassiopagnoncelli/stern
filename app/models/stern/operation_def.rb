module Stern
  class OperationDef < ApplicationRecord
    validates_format_of :name, with: /\A[A-Z][a-zA-Z0-9]*\z/, blank: false
    validates_presence_of :active
    validates_presence_of :undo_capability

    has_many :operations, class_name: 'Stern::Operation', primary_key: :name, foreign_key: :name
  end
end
