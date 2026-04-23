Stern::Engine.routes.draw do
  root to: "home#index"

  scope "auth", module: "auth", as: :auth do
    get    "idp/callback",       to: "callbacks#create",  as: :idp_callback
    post   "idp/callback",       to: "callbacks#create"
    get    "failure",            to: "callbacks#failure", as: :failure
    delete "sign_out",           to: "callbacks#destroy", as: :sign_out
    get    "sign_out/completed", to: "callbacks#signed_out", as: :sign_out_completed
  end

  namespace :admin do
    root to: "dashboard#show"
  end
end
