module Stern
  module Admin
    class LedgerController < ::Stern::AuthenticatedController
      PER_PAGE_OPTIONS = [ 5, 25, 100, 500 ].freeze
      DECIMAL_PLACES_OPTIONS = (0..10).to_a.freeze

      def index
        redirect_to admin_ledger_entries_path(
          params.permit(:gid, :book_id, :currency, :start_date, :end_date,
                        :decimal_places, :page, :per_page)
        )
      end

      def entries
        load_common_params
        @gid = params[:gid].presence
        @book_id = params[:book_id].presence
        @page = [ (params[:page] || 1).to_i, 1 ].max
        per_page_param = params[:per_page].to_i
        @per_page = PER_PAGE_OPTIONS.include?(per_page_param) ? per_page_param : 5
        @books = chart_books
        @book_groups = grouped_chart_books

        if @book_id.present?
          @entries = ::Stern::EntriesQuery.new(
            book_id: @book_id.to_i,
            currency: @currency,
            start_date: @start_date,
            end_date: @end_date,
            gid: @gid&.to_i,
            page: @page,
            per_page: @per_page
          ).call
          @total_entries = entry_count_scope.count
        else
          @entries = []
          @total_entries = 0
        end

        @total_pages = [ (@total_entries.to_f / @per_page).ceil, 1 ].max
        if @entries.any?
          @start_record = (@page - 1) * @per_page + 1
          @end_record = @start_record + @entries.size - 1
        else
          @start_record = 0
          @end_record = 0
        end
      end

      def balance_sheet
        load_common_params
        @books = chart_books
        @book_groups = grouped_chart_books
        @book_ids = Array(params[:book_ids]).reject(&:blank?).map(&:to_i).select(&:positive?)
        query_book_ids = @book_ids.presence || @books.values
        @balance_sheet = ::Stern::BalanceSheetQuery.new(
          start_date: @start_date,
          end_date: @end_date,
          currency: @currency,
          book_ids: query_book_ids
        ).call
      end

      private

      def load_common_params
        @start_date = parse_dt(params[:start_date]) || DateTime.current.last_month
        @end_date = parse_dt(params[:end_date]) || (DateTime.current + 1.minute)
        @start_date_filter_value = @start_date.strftime("%Y-%m-%dT%H:%M")
        @end_date_filter_value = @end_date.strftime("%Y-%m-%dT%H:%M")
        @decimal_places = if params[:decimal_places].present?
          dp = params[:decimal_places].to_i
          DECIMAL_PLACES_OPTIONS.include?(dp) ? dp : 2
        else
          2
        end
        @currency_groups = grouped_currencies
        @currency = resolve_currency(params[:currency])
      end

      def resolve_currency(name)
        names = ::Stern.currencies.names
        return name.to_s if name.present? && names.include?(name.to_s)
        names.include?("USD") ? "USD" : names.first
      end

      def grouped_currencies
        groups = { "Fiat" => [], "Stablecoins" => [], "Crypto" => [], "Other" => [] }
        ::Stern.currencies.each do |name, code|
          group = case code
                  when 800..899   then "Fiat"
                  when 1000..1999 then "Stablecoins"
                  when 2000..2999 then "Crypto"
                  else "Other"
                  end
          groups[group] << name
        end
        groups.reject { |_, v| v.empty? }
      end

      def chart_books
        ::Stern.chart.books.each_with_object({}) do |(name, book), h|
          next if name.to_s.end_with?("_0")
          h[name] = book.code
        end
      end

      def grouped_chart_books
        chart_books.group_by { |name, _| book_group_for(name.to_s) }
      end

      def book_group_for(name)
        head, second = name.split("_", 3)
        case head
        when "merchant"    then "Merchant"
        when "partner"     then "Partner"
        when "customer"    then "Customer"
        when "wdw"         then "Withdrawals"
        when "payment"     then "Payment"
        when "pp"
          case second
          when "charge"     then "Charge"
          when "refund"     then "Refund"
          when "chargeback" then "Chargeback"
          else "Payment Processing"
          end
        else head.to_s.titleize.presence || "Other"
        end
      end

      def entry_count_scope
        currency_code = ::Stern.currencies.code(@currency)
        scope = ::Stern::Entry
                  .where(book_id: @book_id.to_i, currency: currency_code)
                  .where(timestamp: @start_date..@end_date)
        scope = scope.where(gid: @gid.to_i) if @gid.present?
        scope
      end

      def parse_dt(value)
        return nil if value.blank?
        DateTime.parse(value)
      rescue ArgumentError
        nil
      end
    end
  end
end
