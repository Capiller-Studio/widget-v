# frozen_string_literal: true

class Rack::Attack
  # Rate limits for widget message creation (15 messages per minute per IP)
  throttle("widget/messages/ip", limit: 15, period: 1.minute) do |req|
    if req.post? && req.path.match?(%r{\A(/[a-z]{2}(?:-[A-Za-z]{2,4})?)?/w/[^/]+/[^/]+/messages\z})
      req.ip
    end
  end

  # Rate limits for pre-chat customer submissions (5 per minute per IP)
  throttle("widget/contact/ip", limit: 5, period: 1.minute) do |req|
    if req.post? && req.path.match?(%r{\A(/[a-z]{2}(?:-[A-Za-z]{2,4})?)?/w/[^/]+/[^/]+/contact\z})
      req.ip
    end
  end

  # Rate limits for HMAC identity verification requests (10 per minute per IP)
  throttle("widget/identify/ip", limit: 10, period: 1.minute) do |req|
    if req.post? && req.path.match?(%r{\A(/[a-z]{2}(?:-[A-Za-z]{2,4})?)?/w/[^/]+/[^/]+/identify\z})
      req.ip
    end
  end

  # Rate limits for standalone contact form submissions (5 submissions per minute per IP)
  throttle("widget/contact_form/ip", limit: 5, period: 1.minute) do |req|
    if req.post? && req.path.match?(%r{\A(/[a-z]{2}(?:-[A-Za-z]{2,4})?)?/f/[^/]+/[^/]+\z})
      req.ip
    end
  end

  # Send a 429 response when throttled
  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"]
    now = match_data[:epoch_time]

    headers = {
      "RateLimit-Limit" => match_data[:limit].to_s,
      "RateLimit-Remaining" => "0",
      "RateLimit-Reset" => (now + (match_data[:period] - (now % match_data[:period]))).to_s,
      "Content-Type" => "application/json"
    }

    [ 429, headers, [ { error: "Too many requests. Please try again later." }.to_json ] ]
  end
end
