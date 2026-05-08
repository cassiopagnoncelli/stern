module Stern
  class AuthenticatedController < ApplicationController
    before_action :authenticate!
    before_action :require_platform_admin!
    around_action :use_passport_time_zone
    helper_method :passport_time_zone

    private

    def use_passport_time_zone(&block)
      Time.use_zone(passport_time_zone, &block)
    end

    def passport_time_zone
      name = current_passport&.user? ? current_passport.time_zone : nil
      Time.find_zone(name.to_s) || Time.find_zone("UTC")
    rescue Idp::JWT::NotAUserToken
      Time.find_zone("UTC")
    end
  end
end
