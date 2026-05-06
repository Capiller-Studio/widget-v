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

    widget = Channel::WebWidget.find_by(account_id: @account_id, id: @widget_id)
    @theme_color = widget&.theme_color

    response.headers["Content-Type"] = "application/javascript"
    response.headers["Cache-Control"] = "public, max-age=3600, s-maxage=86400"
    response.headers["X-Content-Type-Options"] = "nosniff"

    render layout: false
  end

  def show_form
    @account_id = params[:account_id]
    @form_id    = params[:form_id]

    form = Channel::ContactForm.find_by(account_id: @account_id, id: @form_id)
    @theme_color = form&.configurations&.dig("primary_color") || "#778DFF"

    response.headers["Content-Type"] = "application/javascript"
    response.headers["Cache-Control"] = "public, max-age=3600, s-maxage=86400"
    response.headers["X-Content-Type-Options"] = "nosniff"

    render layout: false
  end
end
