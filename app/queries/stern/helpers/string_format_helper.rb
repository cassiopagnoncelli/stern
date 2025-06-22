# frozen_string_literal: true

module Stern
  module Helpers
    module StringFormatHelper
      def self.format_string(string, format)
        case format
        when :drop_first_word
          string.split(" ").drop(1).join(" ")
        when :drop_last_word
          string.split(" ")[0...-2].join(" ")
        when :titleize
          string.titleize
        when :camelize
          string.camelize
        when :underscore
          string.underscore
        when :dasherize
          string.dasherize
        when :demodulize
          string.demodulize
        when :tableize
          string.tableize
        when :classify
          string.classify
        when :humanize
          string.humanize
        when :upcase_first
          string.sub(/^./, &:upcase)
        when :downcase_first
          string.sub(/^./, &:downcase)
        when :pluralize
          string.pluralize
        when :singularize
          string.singularize
        else
          string
        end
      end
    end
  end
end
