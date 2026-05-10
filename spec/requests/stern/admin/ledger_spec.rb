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

    it "renders enriched currency labels in the picker and dropdown" do
      get "/stern/admin/ledger/balance_sheet"
      expect(response.body).to include("BRL — Brazilian Real (R$)")
      expect(response.body).to include("BTC — Bitcoin (₿)")
      # Stablecoins whose symbol equals the ticker omit the trailing parenthetical.
      expect(response.body).to include("USDT — Tether USD")
      expect(response.body).not_to match(/USDT — Tether USD \(USDT\)/)
    end

    it "ships short labels on each currency option for the collapsed select" do
      get "/stern/admin/ledger/balance_sheet"
      expect(response.body).to include('data-bs-currency-select')
      expect(response.body).to match(/data-bs-short="R\$"/)
      expect(response.body).to match(/data-bs-short="₿"/)
      # Symbol-equals-ticker case: short label is the ticker itself.
      expect(response.body).to match(/data-bs-short="USDT"/)
    end

    it "no longer renders the Decimal places filter" do
      get "/stern/admin/ledger/balance_sheet"
      expect(response.body).not_to include("Decimal places")
      expect(response.body).not_to match(/name="decimal_places"/)
    end
  end

  describe "GET /stern/admin/ledger/entries decimal_places filter" do
    it "is not rendered" do
      get "/stern/admin/ledger/entries"
      expect(response.body).not_to include("Decimal places")
      expect(response.body).not_to match(/name="decimal_places"/)
    end
  end

  describe "currency-driven decimal places" do
    it "uses the catalog default for the chosen currency" do
      query = instance_double(::Stern::EntriesQuery, call: [
        { timestamp: Time.current, gid: 1, code: 1, amount: 12345678, ending_balance: 12345678 }
      ])
      allow(::Stern::EntriesQuery).to receive(:new).and_return(query)
      allow(::Stern::Entry).to receive_message_chain(:where, :where, :count).and_return(1)

      # BTC: catalog says 8 decimal places — 12345678 / 1e8 = 0.12345678
      get "/stern/admin/ledger/entries", params: { book_id: ::Stern.chart.book_codes.first, currency: "BTC" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("0.12345678")
    end
  end

  describe "passport time zone" do
    it "interprets datetime-local params as wall-clock in the passport's zone" do
      sign_in_as(build_passport(platform_admin: true, time_zone: "America/Sao_Paulo"))

      query = instance_double(::Stern::EntriesQuery, call: [])
      allow(::Stern::EntriesQuery).to receive(:new).and_return(query)

      get "/stern/admin/ledger/entries", params: {
        book_id: ::Stern.chart.book_codes.first,
        currency: "USD",
        start_date: "2026-05-07T00:00",
        end_date: "2026-05-07T23:59"
      }

      expect(response).to have_http_status(:ok)
      expect(::Stern::EntriesQuery).to have_received(:new) do |kwargs|
        expect(kwargs[:start_date].utc).to eq(Time.utc(2026, 5, 7, 3, 0))
        expect(kwargs[:end_date].utc).to eq(Time.utc(2026, 5, 8, 2, 59))
      end
    end

    it "falls back to UTC when the passport has no time_zone claim" do
      query = instance_double(::Stern::EntriesQuery, call: [])
      allow(::Stern::EntriesQuery).to receive(:new).and_return(query)

      get "/stern/admin/ledger/entries", params: {
        book_id: ::Stern.chart.book_codes.first,
        currency: "USD",
        start_date: "2026-05-07T00:00",
        end_date: "2026-05-07T23:59"
      }

      expect(::Stern::EntriesQuery).to have_received(:new) do |kwargs|
        expect(kwargs[:start_date].utc).to eq(Time.utc(2026, 5, 7, 0, 0))
        expect(kwargs[:end_date].utc).to eq(Time.utc(2026, 5, 7, 23, 59))
      end
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
