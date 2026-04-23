require "rails_helper"

RSpec.describe "Stern::Auth::Callbacks", type: :request do
  describe "GET /stern/auth/failure" do
    it "renders the auth failure page" do
      get "/stern/auth/failure", params: { message: "invalid_credentials" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to include("Sign-in failed")
      expect(response.body).to include("invalid_credentials")
    end
  end

  describe "GET /stern/auth/sign_out/completed" do
    it "renders the signed-out confirmation" do
      get "/stern/auth/sign_out/completed"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("signed out")
    end
  end

  describe "GET /stern/auth/idp/callback without omniauth.auth" do
    it "renders the failure page when the token is missing" do
      get "/stern/auth/idp/callback"

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to include("Sign-in failed")
    end
  end
end
