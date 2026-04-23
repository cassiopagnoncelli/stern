# frozen_string_literal: true

require "omniauth"
require "omniauth_openid_connect"

# Only configure OmniAuth when the required OAuth2/OIDC credentials are present.
# In test environments or during setup, the JWT helper handles authentication directly.
if (ENV["IDP_JWT_ISSUER"] || ENV["IDP_URL"])&.start_with?("http://")
  SWD.url_builder = URI::HTTP
end

if ENV["IDP_CLIENT_ID"].present?
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect,
      name: :idp,
      scope: %i[openid profile email],
      response_type: :code,
      issuer: ENV.fetch("IDP_JWT_ISSUER", ENV["IDP_URL"]),
      discovery: true,
      request_path: "/stern/auth/idp/start",
      callback_path: "/stern/auth/idp/callback",
      client_options: {
        identifier: ENV.fetch("IDP_CLIENT_ID"),
        secret: ENV.fetch("IDP_CLIENT_SECRET"),
        redirect_uri: ENV.fetch("IDP_REDIRECT_URI", "http://localhost:3016/stern/auth/idp/callback")
      }
  end

  OmniAuth.config.allowed_request_methods = %i[get post]
  OmniAuth.config.silence_get_warning = true
end
