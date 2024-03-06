module Stern
  class Operation < ApplicationRecord
    enum :direction, { do: 1, undo: -1 }

    validates :operation_def_id, presence: true
    validates :direction, presence: true
    validates :params, presence: true, allow_blank: true

    has_many :txs, class_name: "Stern::Tx"
    belongs_to :operation_def, class_name: "Stern::OperationDef", optional: true,
                               primary_key: :operation_def_id, foreign_key: :id

    def self.build(name:, direction: :do, params: {})
      operation_def_id = OperationDef.get_id_by_name!(name)
      new(operation_def_id:, direction:, params:)
    end

    # Effectively replaces delegation to OperationDef saving a database query.
    def name
      OperationDef::Definitions.operation_classes_by_id[operation_def_id].name.gsub("Stern::", "")
    end
  end
end
