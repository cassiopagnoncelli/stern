# frozen_string_literal: true

require "yaml"

module Stern
  class Currencies
    include Enumerable

    def self.load(path)
      new(YAML.load_file(path))
    end

    def initialize(catalog)
      @by_name = catalog.freeze
      @by_code = catalog
        .each_with_object({}) { |(name, code), h|
          h[code] = name if h[code].nil? || name == name.upcase
        }
        .freeze
      freeze
    end

    def code(name)
      @by_name[name.to_s]
    end

    def name(code)
      @by_code[code]
    end

    def names
      @by_name.keys
    end

    def codes
      @by_code.keys
    end

    def each(&block)
      @by_name.each(&block)
    end
  end
end
