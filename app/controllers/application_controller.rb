# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # NOTE: Do NOT add `allow_browser` here. The widget runs inside iframes
  # on third-party customer websites where we cannot control browser versions.
  # Blocking older browsers (Safari <17.2, in-app WebViews, etc.) would break
  # the widget for those visitors.

  include Pagy::Backend

  # The widget is designed to run inside an iframe on customer websites.
  # Remove X-Frame-Options so browsers allow the embedding.
  after_action :allow_iframe_embedding

  private

  def allow_iframe_embedding
    response.headers.delete("X-Frame-Options")
  end
end
