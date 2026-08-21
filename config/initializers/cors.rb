# frozen_string_literal: true

# CORS configuration for the Widget app.
#
# The widget is loaded inside an iframe on customer websites (any origin).
# The embed.js script is loaded cross-origin via a <script> tag.
# Both require permissive CORS headers.

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  # Embed script and widget iframe — allow from any origin
  allow do
    origins "*"

    resource "/*/embed.js",
             headers: :any,
             methods: [ :get ],
             max_age: 3600

    resource "/cable",
             headers: :any,
             methods: [ :get, :post ],
             max_age: 600
  end
end
