module Stern
  class Operation < ApplicationRecord
    enum :direction, { do: 1, undo: -1 }

    has_many :entry_pairs, class_name: "Stern::EntryPair", dependent: :restrict_with_exception

    validates :name, presence: true, allow_blank: false, allow_nil: false
    validates :direction, presence: true
    validates :params, presence: true, allow_blank: true
    validates :idem_key, 
      presence: true,
      allow_blank: true,
      uniqueness: true,
      length: { minimum: 10, maximum: 20, allow_nil: true, allow_blank: false }

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

    def pp
      params_flat = flatten_params(params).map { |k, v| "#{k}:#{v}" }.join(" ") if params
      params_flat ||= "N/A"

      colorize_output([
        ["Operation", :white],
        ["#{format("%5s", id)}", :white, :bold],
        ["|", :white],
        [updated_at, :purple, :bold],
        ["|", :white],
        ["Name:", :white],
        [format("%-15s", name || "N/A"), :white, :bold],
        ["|", :white],
        ["Direction:", :white],
        [format("%-4s", direction || "N/A"), :cyan, :bold],
        ["|", :white],
        ["Idemp:", :white],
        [format("%-20s", idem_key || "N/A"), :orange, :bold],
        ["|", :white],
        ["Params:", :white],
        [params_flat, :yellow, :bold]
      ])
    end

    private

    def flatten_params(hash, parent_key = "", separator = ".")
      hash.each_with_object({}) do |(k, v), h|
        new_key = parent_key.empty? ? k : "#{parent_key}#{separator}#{k}"
        if v.is_a?(Hash)
          h.merge!(flatten_params(v, new_key, separator))
        else
          h[new_key] = v
        end
      end
    end
  end
end
