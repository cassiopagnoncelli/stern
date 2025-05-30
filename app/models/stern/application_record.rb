module Stern
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    establish_connection "stern_#{Rails.env}".to_sym

    # Generates an unique gid to be used across entries, entry_pairs, and operations.
    def self.generate_gid
      connection.execute("SELECT nextval('gid_seq')").first.values.first
    end

    def self.lock_table(table:)
      connection.execute("LOCK TABLE #{table.strip} IN ACCESS SHARE MODE;")
    end

    private

    def colorize_output(parts)
      colors = {
        red: 31, green: 32, yellow: 33, blue: 34,
        magenta: 35, cyan: 36, white: 37, 
        dark_green: "38;5;22", orange: "38;5;208", 
        purple: "38;5;93", lime: "38;5;154"
      }
      
      output = ""
      parts.each_with_index do |part, index|
        text, color, bold = part
        color_code = colors[color]
        
        # Handle both standard colors (integers) and 256-colors (strings)
        if color_code.is_a?(String)
          # 256-color format
          if bold
            output += "\e[1;#{color_code}m#{text}\e[0m"
          else
            output += "\e[#{color_code}m#{text}\e[0m"
          end
        else
          # Standard color format
          if bold
            output += "\e[1;#{color_code}m#{text}\e[0m"
          else
            output += "\e[#{color_code}m#{text}\e[0m"
          end
        end
        
        output += " " unless index == parts.length - 1
      end
      
      puts output
    end
  end
end
