# frozen_string_literal: true

class EmbedController < ApplicationController
  skip_before_action :verify_authenticity_token

  # GET /:account_id/:widget_id/embed.js
  #
  # Returns the JavaScript snippet that customers place on their websites.
  # The script creates an iframe shell WITHOUT src. The src is only set when
  # the visitor clicks the chat bubble (deferred loading = zero perf impact).
  def show
    @account_id = params[:account_id]
    @widget_id  = params[:widget_id]

    account = Account.find_by(id: @account_id)
    if account
      account.with_shard do
        widget = Channel::WebWidget.find_by(account_id: @account_id, id: @widget_id)
        @theme_color = widget&.theme_color
        if widget&.account&.feature_enabled?(:custom_branding) && widget&.custom_branding? && widget&.launcher_icon&.attached?
          @widget_logo_url = rails_blob_url(widget.scaled_launcher_icon)
        end
      end
    end

    response.headers["Content-Type"] = "application/javascript"
    response.headers["Cache-Control"] = "public, max-age=3600, s-maxage=86400, stale-while-revalidate=600"
    response.headers["X-Content-Type-Options"] = "nosniff"

    render(layout: false)
  end

  def show_form
    @account_id = params[:account_id]
    @form_id    = params[:form_id]

    account = Account.find_by(id: @account_id)
    if account
      account.with_shard do
        form = Channel::ContactForm.find_by(account_id: @account_id, id: @form_id)
        @theme_color = form&.theme_color || form&.ui_configurations&.dig("theme_color") || form&.configurations&.dig("primary_color") || "#778DFF"
      end
    else
      @theme_color = "#778DFF"
    end

    response.headers["Content-Type"] = "application/javascript"
    response.headers["Cache-Control"] = "public, max-age=3600, s-maxage=86400, stale-while-revalidate=600"
    response.headers["X-Content-Type-Options"] = "nosniff"

    render(layout: false)
  end
end
