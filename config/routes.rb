Stern::Engine.routes.draw do
  scope "auth", module: "auth", as: :auth do
    get    "idp/callback",       to: "callbacks#create",  as: :idp_callback
    post   "idp/callback",       to: "callbacks#create"
    get    "failure",            to: "callbacks#failure", as: :failure
    delete "sign_out",           to: "callbacks#destroy", as: :sign_out
    get    "sign_out/completed", to: "callbacks#signed_out", as: :sign_out_completed
  end

  namespace :admin do
    root to: "dashboard#show"

    get "ledger",               to: "ledger#index"
    get "ledger/entries",       to: "ledger#entries",       as: :ledger_entries
    get "ledger/balance_sheet", to: "ledger#balance_sheet", as: :ledger_balance_sheet
  end

  root to: "admin/dashboard#show"
end
