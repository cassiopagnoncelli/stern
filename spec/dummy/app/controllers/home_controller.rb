class HomeController < ApplicationController
  include Stern::IdpAuthentication

  def index
    if authenticated?
      redirect_to "/stern/admin"
    else
      redirect_to "/stern/auth/idp/start", allow_other_host: true
    end
  end
end
