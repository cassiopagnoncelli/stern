# frozen_string_literal: true

Idp::JWT.configure do |config|
  config.jwks_url = ENV.fetch("IDP_JWKS_URL", config.jwks_url)
  config.issuer   = ENV.fetch("IDP_JWT_ISSUER", config.issuer)
  config.logger   = Rails.logger
end
