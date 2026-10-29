Rails.application.routes.draw do
  resource :session
  get "up" => "rails/health#show", as: :rails_health_check

  root "home#show"
  get "reports" => "overview#show", as: :reports
  get "page" => "pages#show", as: :page
  get "realtime" => "realtime#show", as: :realtime
  get "realtime/pages" => "realtime#pages", as: :realtime_pages
  get "heatmap" => "heatmaps#show", as: :heatmap
end
