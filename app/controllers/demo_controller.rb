# frozen_string_literal: true

class DemoController < ActionController::Base
  # Intentionally inherits from ActionController::Base (not ApplicationController)
  # because this page simulates a CUSTOMER'S website — it should NOT have
  # widget-specific before_actions, iframe headers, etc.

  layout false

  def show
    @account_id = params[:account_id]
    @widget_id  = params[:widget_id]

    widget = Channel::WebWidget.find_by(account_id: @account_id, id: @widget_id)

    if widget.nil?
      return render plain: "Widget not found. Run Seeds::WebWidgetSeeder.seed first.", status: :not_found
    end

    # Pre-compute HMAC for the test customer so the demo "just works"
    @identifier = "test-customer-001"
    @signature  = OpenSSL::HMAC.hexdigest("sha256", widget.secret, @identifier)
    @email      = "customer@example.com"
    @name       = "Jane Doe"
  end

  def show_form
    @account_id = params[:account_id]
    @form_id    = params[:form_id]

    form = Channel::ContactForm.find_by(account_id: @account_id, id: @form_id)

    if form.nil?
      return render plain: "Contact Form not found. Run seeds or create one first.", status: :not_found
    end

    @identifier = "test-customer-001"
    @signature  = OpenSSL::HMAC.hexdigest("sha256", form.secret, @identifier)
    @email      = "customer@example.com"
    @name       = "Jane Doe"
  end
end
