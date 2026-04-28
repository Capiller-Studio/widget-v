# frozen_string_literal: true

Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Demo page — simulates a customer website with the widget embedded (dev/test only)
  get "demo/:account_id/:widget_id", to: "demo#show", as: :demo if Rails.env.local?

  # ActionCable WebSocket endpoint
  mount ActionCable.server => "/cable"

  # Embed script endpoint (served cross-origin via <script> tag)
  get ":account_id/:widget_id/embed.js", to: "embed#show", as: :embed_script, defaults: { format: :js }

  scope "(:locale)", locale: /[a-z]{2}/ do
    get "home",           to: "widget#home",           as: :home
    get "messages",       to: "widget#messages",       as: :messages
    post "messages",      to: "widget#create_message", as: :create_message
    get "conversations",  to: "widget#conversations",  as: :conversations
    get "knowledge-base", to: "widget#help",           as: :help_center
    get "knowledge-base/categories/:category_id", to: "widget#category", as: :help_category
    get "search",         to: "widget#search",         as: :search

    # Widget entry point: embed.deskbolic.com/:locale/:account_id/:widget_id
    get ":account_id/:widget_id", to: "widget#index", as: :widget_entry
  end
end
