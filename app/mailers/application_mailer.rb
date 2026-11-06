# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: "no-reply@capiller.com"
  layout "mailer"
end
