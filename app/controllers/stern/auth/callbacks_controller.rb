# frozen_string_literal: true

module Stern
  module Auth
    class CallbacksController < ::Stern::ApplicationController
      skip_before_action :verify_authenticity_token, only: %i[create destroy]

      # GET/POST /stern/auth/idp/callback
      def create
        auth = request.env["omniauth.auth"]
        jwt_token = auth&.credentials&.token

        raise Idp::JWT::VerificationError, "missing token" if jwt_token.blank?

        passport = Idp::JWT.verify!(jwt_token)

        session[:idp_jwt] = jwt_token
        session[:idp_refresh_token] = auth.credentials.refresh_token
        session[:idp_logout_hint_token] = logout_hint_token_from(auth, fallback: jwt_token)

        redirect_to after_sign_in_path
      rescue Idp::JWT::VerificationError => e
        Rails.logger.error("Idp JWT verification failed during callback: #{e.message}")
        redirect_to "/stern", alert: "Authentication failed."
      end

      # GET /stern/auth/failure
      def failure
        Rails.logger.warn("OmniAuth authentication failed: #{params[:message]}")
        redirect_to "/stern", alert: "Authentication failed."
      end

      # DELETE /stern/auth/sign_out
      def destroy
        logout_hint_token = session[:idp_logout_hint_token].presence || session[:idp_jwt]
        logout_url = build_end_session_url(logout_hint_token)

        reset_session

        if logout_url.present?
          redirect_to logout_url, allow_other_host: true
        else
          redirect_to "/stern", alert: "Signed out."
        end
      end

      # GET /stern/auth/sign_out/completed
      def signed_out
        reset_session
        redirect_to "/stern", notice: "Signed out."
      end

      private

      def after_sign_in_path
        session.delete(:stern_return_to).presence || "/stern"
      end

      def logout_hint_token_from(auth, fallback:)
        auth.credentials.id_token.presence || auth.extra&.id_token.presence || fallback
      end

      def build_end_session_url(id_token_hint)
        base = ENV["IDP_URL"].presence || ENV["IDP_JWT_ISSUER"]
        return nil if base.blank?

        query = {
          post_logout_redirect_uri: post_logout_redirect_uri,
          id_token_hint: id_token_hint
        }.compact

        "#{base}/oauth/end_session?#{query.to_query}"
      end

      def post_logout_redirect_uri
        "#{request.base_url}/stern/auth/sign_out/completed"
      end
    end
  end
end
