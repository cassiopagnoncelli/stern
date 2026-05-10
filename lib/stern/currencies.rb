# frozen_string_literal: true

require "yaml"

module Stern
  class Currencies
    include Enumerable

    KINDS = %i[unit fiat stablecoin crypto].freeze
    DECIMAL_PLACES_RANGE = (0..18).freeze

    Entry = Data.define(:name, :code, :decimal_places, :symbol, :kind)

    def self.load(path)
      new(YAML.load_file(path))
    end

    def initialize(catalog)
      entries = catalog.map { |name, attrs| build_entry(name, attrs) }
      @by_name = entries.to_h { |e| [ e.name, e ] }.freeze
      @by_code = entries.each_with_object({}) { |e, h| h[e.code] ||= e }.freeze
      validate!
      freeze
    end

    def code(name)
      @by_name[name.to_s]&.code
    end

    def name(code)
      @by_code[code]&.name
    end

    def names
      @by_name.keys
    end

    def codes
      @by_code.keys
    end

    def each(&block)
      @by_name.each { |n, e| block.call(n, e.code) }
    end

    def decimal_places(ref)
      entry(ref)&.decimal_places
    end

    def symbol(ref)
      entry(ref)&.symbol
    end

    def kind(ref)
      entry(ref)&.kind
    end

    def display_name(ref, locale: I18n.locale)
      e = entry(ref) or return nil
      I18n.t("stern.currencies.#{e.name.downcase}.name", locale: locale, default: e.name)
    end

    def entry(ref)
      case ref
      when Integer        then @by_code[ref]
      when String, Symbol then @by_name[ref.to_s.strip.upcase]
      end
    end

    private

    def build_entry(name, attrs)
      raise ArgumentError, "currency #{name.inspect} attrs must be a Hash" unless attrs.is_a?(Hash)

      a = attrs.transform_keys(&:to_s)
      kind = a.fetch("kind").to_sym
      raise ArgumentError, "currency #{name}: kind #{kind.inspect} not in #{KINDS.inspect}" unless KINDS.include?(kind)

      dp = Integer(a.fetch("decimal_places"))
      raise ArgumentError, "currency #{name}: decimal_places #{dp} out of range #{DECIMAL_PLACES_RANGE}" unless DECIMAL_PLACES_RANGE.cover?(dp)

      Entry.new(
        name: name.to_s,
        code: Integer(a.fetch("code")),
        decimal_places: dp,
        symbol: a.fetch("symbol").to_s,
        kind: kind,
      )
    end

    def validate!
      dups = @by_name.values.map(&:code).tally.select { |_, n| n > 1 }.keys
      raise ArgumentError, "duplicate currency codes: #{dups.inspect}" if dups.any?
    end
  end
end
