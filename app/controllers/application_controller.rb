# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  include Pagy::Backend

  # The widget is designed to run inside an iframe on customer websites.
  # Remove X-Frame-Options so browsers allow the embedding.
  after_action :allow_iframe_embedding

  private

  def allow_iframe_embedding
    response.headers.delete("X-Frame-Options")
  end
end
