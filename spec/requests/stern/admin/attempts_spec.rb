require "rails_helper"

RSpec.describe "Stern::Admin::Attempts", type: :request do
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

  # Synthetic operation_id values used in spec rows below. The FK from
  # stern_operation_attempts.operation_id requires an existing stern_operations
  # row (or NULL), so we seed real ones with the same ids the specs reference.
  SPEC_OPERATION_IDS = [ 1, 2, 42 ].freeze

  before do
    sign_in_as(build_passport(platform_admin: true))
    Stern::OperationAttempt.delete_all
    Stern::Repair.clear(confirm: true)
    SPEC_OPERATION_IDS.each do |id|
      Stern::Operation.create!(id:, name: "spec_seed_#{id}", params: {})
    end
  end

  describe "GET /stern/admin/attempts" do
    it "renders with empty state when no attempts exist" do
      get "/stern/admin/attempts"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Operation Attempts")
      expect(response.body).to include("No attempts match")
    end

    it "lists attempts in the window" do
      Stern::OperationAttempt.create!(
        name: "ChargePayment",
        params: { "amount" => 100 },
        idem_key: "key-abc-123",
        status: :success,
        operation_id: 42,
        attempted_at: 1.hour.ago,
      )

      get "/stern/admin/attempts"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ChargePayment")
      expect(response.body).to include("Success")
      expect(response.body).to include("key-abc-123")
    end

    it "filters by status" do
      Stern::OperationAttempt.create!(
        name: "ChargePayment", params: {}, status: :success,
        idem_key: "succ-1234567",
        operation_id: 1, attempted_at: 1.hour.ago,
      )
      Stern::OperationAttempt.create!(
        name: "Deposit", params: {}, status: :failed,
        idem_key: "fail-1234567",
        error_class: "RuntimeError", error_message: "boom",
        attempted_at: 30.minutes.ago,
      )

      get "/stern/admin/attempts", params: { status: "failed" }
      expect(response.body).to include("RuntimeError")
      expect(response.body).to include("fail-1234567")
      expect(response.body).not_to include("succ-1234567")
    end

    it "filters by operation name" do
      Stern::OperationAttempt.create!(
        name: "ChargePayment", params: {}, status: :success,
        idem_key: "cp-12345678",
        operation_id: 1, attempted_at: 1.hour.ago,
      )
      Stern::OperationAttempt.create!(
        name: "Deposit", params: {}, status: :success,
        idem_key: "dep-1234567",
        operation_id: 2, attempted_at: 30.minutes.ago,
      )

      get "/stern/admin/attempts", params: { name: "Deposit" }
      expect(response.body).to include("dep-1234567")
      expect(response.body).not_to include("cp-12345678")
    end

    it "filters by idem_key" do
      Stern::OperationAttempt.create!(
        name: "ChargePayment", params: {}, status: :success,
        idem_key: "match-1234567",
        operation_id: 1, attempted_at: 1.hour.ago,
      )
      Stern::OperationAttempt.create!(
        name: "ChargePayment", params: {}, status: :success,
        idem_key: "other-1234567",
        operation_id: 2, attempted_at: 30.minutes.ago,
      )

      get "/stern/admin/attempts", params: { idem_key: "match-1234567" }
      expect(response.body).to include("match-1234567")
      expect(response.body).not_to include("other-1234567")
    end

    it "shows the menu link for authenticated admins" do
      get "/stern/admin/attempts"
      expect(response.body).to include("Attempts")
      expect(response.body).to include('href="/stern/admin/attempts"')
    end
  end

  describe "auth" do
    it "redirects to idp when unauthenticated" do
      allow_any_instance_of(Stern::ApplicationController)
        .to receive(:authenticated?).and_call_original
      allow_any_instance_of(Stern::ApplicationController)
        .to receive(:current_passport).and_call_original

      get "/stern/admin/attempts"

      expect(response).to have_http_status(:found)
      expect(response.location).to end_with("/stern/auth/idp/start")
    end
  end
end
