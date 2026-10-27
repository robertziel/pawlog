Rails.application.routes.draw do
  resource :session
  get "up" => "rails/health#show", as: :rails_health_check

  root "overview#show"
  get "page" => "pages#show", as: :page
  get "realtime" => "realtime#show", as: :realtime
  get "heatmap" => "heatmaps#show", as: :heatmap
end
