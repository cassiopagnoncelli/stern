module Stern
  class OperationDef < ApplicationRecord
    validates_format_of :name, with: /\A(?!Stern::)[A-Z][a-zA-Z0-9]*\z/, blank: false
    validates_presence_of :active
    validates_presence_of :undo_capability

    has_many :operations, class_name: 'Stern::Operation', primary_key: :operation_def_id, foreign_key: :id

    def self.get_id_by_name!(name)
      if Definitions.operation_classes_by_name.keys.include?(name)
        Definitions.operation_classes_by_name[name]::UID
      else
        OperationDef.find_by!(name:).id
      end
    end
  end
end
