module Stern
  class Operation < ApplicationRecord
    enum :direction, { do: 1, undo: -1 }

    has_many :entry_pairs, class_name: "Stern::EntryPair", dependent: :restrict_with_exception

    validates :name, presence: true, allow_blank: false, allow_nil: false
    validates :direction, presence: true
    validates :params, presence: true, allow_blank: true

    def self.list
      # Get the engine root directory
      engine_root = File.expand_path("../../..", __dir__)
      
      # Get all operation files
      operation_files = Dir[File.join(engine_root, "app", "operations", "stern", "*.rb")]
      
      operation_classes = []
      operation_files.each do |file|
        # Extract filename without extension
        filename = File.basename(file, ".rb")
        
        # Skip base_operation
        next if filename == "base_operation"
        
        # Convert snake_case to CamelCase
        class_name = filename.split("_").map(&:capitalize).join
        operation_classes << class_name
      end

      operation_classes
    end
  end
end
