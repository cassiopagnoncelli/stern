module Stern
  class ScheduledOperation < ApplicationRecord
    enum :status, {
      pending: 0,
      picked: 1,
      in_progress: 2,
      finished: 3,
      canceled: 4,
      argument_error: 11,
      runtime_error: 12,
    }

    validates :name, presence: true, allow_blank: false, allow_nil: false
    validates :params, presence: true, allow_blank: true
    validates :after_time, presence: true
    validates :status, presence: true
    validates :status_time, presence: true

    after_initialize do
      self.params ||= {}
      self.status ||= :pending
      self.status_time ||= DateTime.current.utc
    end

    def self.build(name:, params:, after_time:, status: :pending, status_time: DateTime.current.utc)
      new(name:, params:, after_time:, status:, status_time:)
    end

    def pp
      # Flatten params recursively and prepare for colorized output
      flat_params = flatten_params(params) if params
      params_parts = []
      
      if flat_params&.any?
        flat_params.each_with_index do |(k, v), index|
          params_parts << [k, :white]
          params_parts << ["=", :white]
          params_parts << [v.to_s, :yellow, :bold]
          params_parts << [" ", :white] unless index == flat_params.length - 1
        end
        
        # Join params into single string and remove extra spaces
        params_string = params_parts.map(&:first).join("").gsub(/\s+/, " ").strip
        params_parts = [[params_string, :yellow, :bold]]
      else
        params_parts = [["N/A", :white]]
      end
      
      # Status color logic
      status_color = case status
                    when "finished" then :green
                    when "failed", "error" then :red
                    when "pending", "scheduled" then :yellow
                    when "running", "processing" then :blue
                    else :white
                    end
      
      colorize_output([
        ["ScheduledOperation", :white],
        ["#{format("%5s", id)}", :white, :bold],
        ["|", :white],
        [updated_at, :purple, :bold],
        ["|", :white],
        [format("%s", name || "N/A"), :white, :bold],
        ["|", :white],
        [format("%s", status || "N/A"), status_color, :bold],
        ["|", :white],
        [">=", :white],
        [after_time || "N/A", :cyan, :bold],
        ["|", :white],
        ["Error:", :white],
        [error_message || "none", error_message ? :red : :green, :bold],
        ["|", :white],
        ["Params:", :white]
      ] + params_parts)
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
