require "rails_helper"

RSpec.describe "Stern::Admin::Pruner", type: :request do
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

  before do
    sign_in_as(build_passport(platform_admin: true))
    Stern::OperationAttempt.delete_all
  end

  describe "GET /stern/admin/attempts/pruner" do
    it "renders the page with default retention labels when ENV is unset" do
      stub_const("ENV", ENV.to_h.except("STERN_PRUNE_SUCCESS_DAYS", "STERN_PRUNE_FAILED_DAYS", "STERN_PRUNE_PENDING_DAYS"))

      get "/stern/admin/attempts/pruner"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Operation Attempt Pruner")
      expect(response.body).to include("Configured retention")
      # Defaults applied for the preview, but the labels still show "default"
      # so the operator sees ENV is unset.
      expect(response.body).to include("default")
    end

    it "shows configured retention from ENV when set" do
      stub_const("ENV", ENV.to_h.merge(
        "STERN_PRUNE_SUCCESS_DAYS" => "30",
        "STERN_PRUNE_FAILED_DAYS"  => "120",
        "STERN_PRUNE_PENDING_DAYS" => "10",
      ))

      get "/stern/admin/attempts/pruner"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("30d")
      expect(response.body).to include("120d")
      expect(response.body).to include("10d")
    end

    it "previews the would-delete count for stale rows" do
      Stern::OperationAttempt.create!(
        name: "X", params: {}, status: :success, attempted_at: 30.days.ago,
      )
      Stern::OperationAttempt.create!(
        name: "X", params: {}, status: :success, attempted_at: 1.hour.ago,
      )

      get "/stern/admin/attempts/pruner"

      expect(response.body).to match(/Success.*1/m)
    end
  end

  describe "POST /stern/admin/attempts/pruner/run" do
    it "deletes rows past the cutoff and redirects with a flash" do
      stale = Stern::OperationAttempt.create!(
        name: "X", params: {}, status: :success, attempted_at: 30.days.ago,
      )
      fresh = Stern::OperationAttempt.create!(
        name: "X", params: {}, status: :success, attempted_at: 1.hour.ago,
      )

      post "/stern/admin/attempts/pruner/run"

      expect(response).to redirect_to("/stern/admin/attempts/pruner")
      follow_redirect!
      expect(response.body).to include("Pruned success=1")
      expect(Stern::OperationAttempt.find_by(id: stale.id)).to be_nil
      expect(Stern::OperationAttempt.find_by(id: fresh.id)).to be_present
    end

    it "honours per-status overrides from form params" do
      old_failed = Stern::OperationAttempt.create!(
        name: "X", params: {}, status: :failed, attempted_at: 5.days.ago,
        error_class: "RuntimeError", error_message: "boom",
      )

      post "/stern/admin/attempts/pruner/run", params: { failed_days: "1" }

      expect(Stern::OperationAttempt.find_by(id: old_failed.id)).to be_nil
    end

    it "rejects negative override values with a flash alert" do
      post "/stern/admin/attempts/pruner/run", params: { success_days: "-3" }

      expect(response).to redirect_to("/stern/admin/attempts/pruner")
      follow_redirect!
      expect(response.body).to include("Could not run pruner")
    end

    it "rejects non-integer override values with a flash alert" do
      post "/stern/admin/attempts/pruner/run", params: { success_days: "abc" }

      follow_redirect!
      expect(response.body).to include("Could not run pruner")
    end
  end

  describe "auth gating" do
    it "rejects non-admin users" do
      sign_in_as(build_passport(platform_admin: false))

      get "/stern/admin/attempts/pruner"
      expect(response).to have_http_status(:forbidden)
    end
  end
end
