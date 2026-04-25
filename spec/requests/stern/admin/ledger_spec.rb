require "rails_helper"

RSpec.describe "Stern::Admin::Ledger", type: :request do
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

  before { sign_in_as(build_passport(platform_admin: true)) }

  describe "GET /stern/admin/ledger" do
    it "redirects to entries" do
      get "/stern/admin/ledger"
      expect(response).to have_http_status(:found)
      expect(response.location).to include("/stern/admin/ledger/entries")
    end
  end

  describe "GET /stern/admin/ledger/entries" do
    it "renders with empty state when no book selected" do
      get "/stern/admin/ledger/entries"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ledger Entries")
      expect(response.body).to include("Please select a book ID")
    end

    it "renders the empty-period state when a book is chosen but no entries exist" do
      get "/stern/admin/ledger/entries", params: { book_id: ::Stern.chart.book_codes.first, currency: "USD" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ledger Entries")
      expect(response.body).to include("No entries match your current filters")
    end
  end

  describe "GET /stern/admin/ledger/balance_sheet" do
    it "renders the balance sheet" do
      get "/stern/admin/ledger/balance_sheet"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Balance Sheet")
      expect(response.body).to include("Previous Balance")
      expect(response.body).to include("TOTALS")
    end
  end

  describe "auth" do
    it "redirects to idp when unauthenticated" do
      allow_any_instance_of(Stern::ApplicationController)
        .to receive(:authenticated?).and_call_original
      allow_any_instance_of(Stern::ApplicationController)
        .to receive(:current_passport).and_call_original

      get "/stern/admin/ledger/entries"

      expect(response).to have_http_status(:found)
      expect(response.location).to end_with("/stern/auth/idp/start")
    end
  end
end
