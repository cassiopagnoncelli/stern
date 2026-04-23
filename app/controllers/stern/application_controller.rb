module Stern
  class ApplicationController < ActionController::Base
    include ::Stern::IdpAuthentication
  end
end
