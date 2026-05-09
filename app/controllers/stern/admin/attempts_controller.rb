module Stern
  module Admin
    class AttemptsController < ::Stern::AuthenticatedController
      PER_PAGE_OPTIONS = [ 5, 25, 100, 500 ].freeze

      def index
        @start_date = parse_dt(params[:start_date]) || 1.week.ago
        @end_date = parse_dt(params[:end_date]) || (Time.current + 1.minute)
        @start_date_filter_value = @start_date.in_time_zone.strftime("%Y-%m-%dT%H:%M")
        @end_date_filter_value = @end_date.in_time_zone.strftime("%Y-%m-%dT%H:%M")

        @name = params[:name].presence
        @status = params[:status].presence
        @idem_key = params[:idem_key].presence

        @page = [ (params[:page] || 1).to_i, 1 ].max
        per_page_param = params[:per_page].to_i
        @per_page = PER_PAGE_OPTIONS.include?(per_page_param) ? per_page_param : 25

        @operation_names = ::Stern::Operation.list
        @statuses = ::Stern::OperationAttempt.statuses.keys

        query = ::Stern::OperationAttemptsQuery.new(
          name: @name,
          status: @status,
          idem_key: @idem_key,
          start_date: @start_date,
          end_date: @end_date,
          page: @page,
          per_page: @per_page,
        )
        @attempts = query.call.to_a
        @total_attempts = query.total_count
        @total_pages = [ (@total_attempts.to_f / @per_page).ceil, 1 ].max
        if @attempts.any?
          @start_record = (@page - 1) * @per_page + 1
          @end_record = @start_record + @attempts.size - 1
        else
          @start_record = 0
          @end_record = 0
        end
      end

      private

      def parse_dt(value)
        return nil if value.blank?
        Time.zone.parse(value)
      rescue ArgumentError
        nil
      end
    end
  end
end
