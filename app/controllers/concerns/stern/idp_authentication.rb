# frozen_string_literal: true

module Stern
  module IdpAuthentication
    extend ActiveSupport::Concern

    included do
      helper_method :current_passport, :authenticated?
    end

    def current_passport
      @current_passport ||= load_passport_from_session
    end

    def authenticated?
      current_passport.present?
    end

    def authenticate!
      return if authenticated?

      respond_to do |format|
        format.html do
          session[:stern_return_to] = request.fullpath
          redirect_to idp_login_path, allow_other_host: true
        end
        format.json { render json: { error: "unauthenticated" }, status: :unauthorized }
      end
    end

    def require_platform_admin!
      return if current_passport&.platform_admin? || current_passport&.platform_admin_root?

      respond_to do |format|
        format.html do
          redirect_to "/stern", alert: "You are not authorized to access this area."
        end
        format.json { render json: { error: "forbidden" }, status: :forbidden }
      end
    end

    private

    def load_passport_from_session
      token = session[:idp_jwt]
      return nil unless token

      passport = jwt_verifier.verify!(token)
      return nil if passport.expired?

      passport
    rescue Idp::JWT::VerificationError
      clear_session_and_return_nil
    end

    def clear_session_and_return_nil
      session.delete(:idp_jwt)
      session.delete(:idp_refresh_token)
      session.delete(:idp_logout_hint_token)
      nil
    end

    def jwt_verifier
      @jwt_verifier ||= Idp::JWT::Verifier.new
    end

    def idp_login_path
      "/stern/auth/idp/start"
    end
  end
end
