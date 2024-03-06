module Stern
  class OperationDef
    class Definitions
      cattr_accessor :operation_classes, :operation_classes_by_id, :operation_classes_by_name

      @@operation_classes = list_operations
      @@operation_classes_by_id = @@operation_classes.index_by do |c|
        c::UID
      end
      @@operation_classes_by_name = @@operation_classes.index_by do |c|
        c.name.gsub("Stern::", "")
      end

      def self.persist
        @@operation_classes.each do |op|
          name = op.name.gsub("Stern::", "")
          next if OperationDef.find_by(name:)

          OperationDef.create!(
            id: op::UID,
            name:,
            active: true,
            undo_capability: op.new.respond_to?(:perform_undo),
          )
          Rails.logger.info "Registered operation #{name}"
        end
      end
    end
  end
end
