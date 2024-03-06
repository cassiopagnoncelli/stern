module Stern
  class OperationDef < ApplicationRecord
    validates :name, format: { with: /\A(?!Stern::)[A-Z][a-zA-Z0-9]*\z/, blank: false }
    validates :active, presence: true
    validates :undo_capability, presence: true

    has_many :operations, class_name: "Stern::Operation", primary_key: :operation_def_id,
                          foreign_key: :id

    def self.get_id_by_name!(name)
      if Definitions.operation_classes_by_name.keys.include?(name)
        Definitions.operation_classes_by_name[name]::UID
      else
        OperationDef.find_by!(name:).id
      end
    end
  end
end
