# frozen_string_literal: true

Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Demo page — simulates a customer website with the widget embedded (dev/test only)
  get "demo/widget/:account_id/:widget_id", to: "demo#show", as: :demo if Rails.env.local?
  get "demo/form/:account_id/:form_id", to: "demo#show_form", as: :demo_form if Rails.env.local?


  # Embed script endpoint (served cross-origin via <script> tag)
  get "w/:account_id/:widget_id/embed.js", to: "embed#show", as: :embed_script, defaults: { format: :js }
  get "f/:account_id/:form_id/embed.js", to: "embed#show_form", as: :embed_form_script, defaults: { format: :js }

  scope "(:locale)", locale: /[a-z]{2}(-[A-Z]{2})?/ do
    scope "w/:account_id/:widget_id", as: :widget do
      get "/",              to: "widget#index",          as: :root
      get "home",           to: "widget#home",           as: :home
      get "messages",       to: "widget#messages",       as: :messages
      post "messages",      to: "widget#create_message", as: :create_message
      get "conversations",  to: "widget#conversations",  as: :conversations
      get "knowledge-base", to: "widget#help",           as: :help_center
      get "knowledge-base/categories/:category_id", to: "widget#category", as: :help_category
      get "knowledge-base/categories/:category_id/articles/:article_id", to: "widget#article", as: :help_article
      get "search",         to: "widget#search",         as: :search
      post "contact",       to: "widget#create_customer", as: :create_customer
    end

    # Form entry point: embed.deskbolic.com/:locale/f/:account_id/:form_id
    get "f/:account_id/:form_id", to: "contact_forms#show", as: :contact_form_entry
    post "f/:account_id/:form_id", to: "contact_forms#create", as: :contact_form_submit
  end
end
