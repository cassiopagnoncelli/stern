module Stern
  module Admin
    class BalanceSheetPreset
      CONFIG_PATH = ::Stern::Engine.root.join("config", "balance_sheet_presets.yml").freeze

      DATE_RANGE_KEYS = %w[
        today yesterday
        this_week last_week
        this_month last_month
        this_quarter last_quarter
        this_year last_year
      ].freeze

      attr_reader :key, :label, :description, :currency, :decimal_places,
                  :date_range, :start_date, :end_date, :book_names

      class << self
        def all
          @all ||= load!
        end

        def reload!
          @all = nil
          all
        end

        private

        def load!
          raw = YAML.load_file(CONFIG_PATH)
          entries = Array(raw && raw["presets"])
          presets = entries.map { |e| new(e) }
          validate_unique_keys!(presets)
          validate_books!(presets)
          presets.freeze
        end

        def validate_unique_keys!(presets)
          dupes = presets.map(&:key).tally.select { |_, n| n > 1 }.keys
          return if dupes.empty?
          raise ArgumentError, "duplicate balance sheet preset keys: #{dupes.inspect}"
        end

        def validate_books!(presets)
          known = ::Stern.chart.books.each_key.map(&:to_s).to_set
          presets.each do |p|
            unknown = p.book_names.reject { |n| known.include?(n) }
            next if unknown.empty?
            raise ArgumentError,
                  "unknown book(s) in preset #{p.key.inspect}: #{unknown.inspect}"
          end
        end
      end

      def initialize(attrs)
        a = attrs.transform_keys(&:to_s)
        @key = a.fetch("key").to_s
        @label = a.fetch("label").to_s
        @description = a["description"].to_s
        @currency = a.fetch("currency").to_s
        @decimal_places = a["decimal_places"]
        @date_range = a["date_range"]&.to_s
        @start_date = a["start_date"]&.to_s
        @end_date = a["end_date"]&.to_s
        @book_names = Array(a["book_names"]).map(&:to_s)
        validate!
        freeze
      end

      def to_payload(book_name_to_code)
        {
          key: key,
          label: label,
          currency: currency,
          decimal_places: decimal_places,
          date_range: date_range,
          start_date: start_date,
          end_date: end_date,
          book_ids: book_names.map { |n| book_name_to_code.fetch(n.to_sym).to_i }
        }.compact
      end

      private

      def validate!
        raise ArgumentError, "preset key is blank" if key.empty?
        raise ArgumentError, "preset #{key.inspect} label is blank" if label.empty?
        raise ArgumentError, "preset #{key.inspect} currency is blank" if currency.empty?
        raise ArgumentError, "preset #{key.inspect} has no books" if book_names.empty?

        if date_range.present?
          unless DATE_RANGE_KEYS.include?(date_range)
            raise ArgumentError,
                  "preset #{key.inspect} date_range #{date_range.inspect} not in #{DATE_RANGE_KEYS.inspect}"
          end
        elsif start_date.blank? || end_date.blank?
          raise ArgumentError,
                "preset #{key.inspect} must set date_range OR both start_date and end_date"
        end

        if decimal_places && !(0..10).cover?(decimal_places)
          raise ArgumentError,
                "preset #{key.inspect} decimal_places must be 0..10"
        end
      end
    end
  end
end
