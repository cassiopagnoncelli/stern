require "rails_helper"

# Verifies the load-bearing invariant declared in CLAUDE.md:
# AuthenticatedController wraps every request in
# Time.use_zone(passport_time_zone). Without it, every admin view silently
# renders in UTC.
RSpec.describe "Stern::AuthenticatedController time zone wrapping", type: :request do
  def build_passport(user_overrides = {}, claim_overrides = {})
    user_claims = { email: "admin@example.com", platform_admin: true }.merge(user_overrides)
    Idp::JWT::Passport.new(
      {
        iss: "http://localhost:3011",
        sub: "usr_admin",
        iat: Time.now.to_i,
        exp: 1.hour.from_now.to_i,
        jti: "tok_admin",
        user: user_claims
      }.merge(claim_overrides)
    )
  end

  def sign_in_as(passport)
    allow_any_instance_of(Stern::ApplicationController)
      .to receive(:current_passport).and_return(passport)
    allow_any_instance_of(Stern::ApplicationController)
      .to receive(:authenticated?).and_return(true)
  end

  # Capture Time.zone.name at the moment the controller action runs —
  # i.e. inside the around_action wrap.
  def capture_zone_during_action
    captured = nil
    allow_any_instance_of(Stern::Admin::DashboardController)
      .to receive(:show).and_wrap_original do |original, *args|
        captured = Time.zone.name
        original.call(*args)
      end
    yield
    captured
  end

  it "wraps the action in the passport's time zone" do
    sign_in_as(build_passport(time_zone: "America/Sao_Paulo"))

    zone = capture_zone_during_action do
      get "/stern/admin"
    end

    expect(response).to have_http_status(:ok)
    expect(zone).to eq("America/Sao_Paulo")
  end

  it "falls back to UTC when the passport has no time_zone claim" do
    sign_in_as(build_passport) # no :time_zone in user claims

    zone = capture_zone_during_action do
      get "/stern/admin"
    end

    expect(response).to have_http_status(:ok)
    expect(zone).to eq("UTC")
  end

  it "falls back to UTC when the time_zone claim is an unknown zone name" do
    sign_in_as(build_passport(time_zone: "Not/A_Real_Zone"))

    zone = capture_zone_during_action do
      get "/stern/admin"
    end

    expect(response).to have_http_status(:ok)
    expect(zone).to eq("UTC")
  end

end
