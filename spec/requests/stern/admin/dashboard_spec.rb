require "rails_helper"

RSpec.describe "Stern::Admin::Dashboard", type: :request do
  def build_passport(overrides = {})
    Idp::JWT::Passport.new(
      iss: "http://localhost:3011",
      sub: "usr_admin",
      iat: Time.now.to_i,
      exp: 1.hour.from_now.to_i,
      jti: "tok_admin",
      user: { email: "admin@example.com", platform_admin: true }.merge(overrides)
    )
  end

  def sign_in_as(passport)
    allow_any_instance_of(Stern::ApplicationController)
      .to receive(:current_passport).and_return(passport)
    allow_any_instance_of(Stern::ApplicationController)
      .to receive(:authenticated?).and_return(true)
  end

  describe "GET /stern/admin" do
    it "redirects to idp login when unauthenticated" do
      get "/stern/admin"

      expect(response).to have_http_status(:found)
      expect(response.location).to end_with("/stern/auth/idp/start")
    end

    it "redirects to /stern when signed-in user lacks platform_admin" do
      sign_in_as(build_passport(platform_admin: false))

      get "/stern/admin"

      expect(response).to redirect_to("/stern")
      expect(flash[:alert]).to match(/not authorized/i)
    end

    it "renders the dashboard for a platform admin" do
      sign_in_as(build_passport(platform_admin: true))

      get "/stern/admin"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("admin@example.com")
      expect(response.body).to include("platform_admin")
    end

    it "renders for a platform_admin_root even when platform_admin is false" do
      sign_in_as(build_passport(email: "root@example.com", platform_admin: false, platform_admin_root: true))

      get "/stern/admin"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("platform_admin_root")
    end
  end
end
