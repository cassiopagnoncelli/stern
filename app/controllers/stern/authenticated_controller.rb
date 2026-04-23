module Stern
  class AuthenticatedController < ApplicationController
    before_action :authenticate!
    before_action :require_platform_admin!
  end
end
