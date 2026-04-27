Rails.application.routes.draw do
  mount Stern::Engine => "/stern"

  root to: "home#index"
end
