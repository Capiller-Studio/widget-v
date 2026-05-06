# frozen_string_literal: true

class ContactFormsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:create]
  before_action :set_locale
  before_action :set_form
  before_action :verify_hmac, if: -> { @form.require_login? }

  layout "widget"

  def show
    @custom_fields = @form.custom_fields.includes(:translations).order("custom_field_resources.position ASC")
    
    @customer_data = {
      name: params[:name],
      email: params[:email]
    }
  end

  def create
    if params[:nickname].present?
      render plain: "Spam detected.", status: :ok
      return
    end

    conversation = Channels::ContactForms::ConversationCreator.call(
      contact_form_channel: @form,
      form_params: params.except(:action, :controller, :account_id, :form_id, :locale, :signature, :identifier),
      attachments: params[:attachments]
    )

    if conversation
      if @form.configurations["submit_redirect_url"].present?
        redirect_to @form.configurations["submit_redirect_url"], allow_other_host: true
      else
        @success_message = I18n.t(@form.configurations["success_message_i18n_key"] || "contact_form.success", default: "Thank you! Your message has been received.")
        render :success
      end
    else
      redirect_to contact_form_entry_path, alert: "Something went wrong. Please try again."
    end
  end

  private

  def set_locale
    I18n.locale = params[:locale] || I18n.default_locale
  end

  def set_form
    @account = Account.find(params[:account_id])
    @form = Channel::ContactForm.find_by!(account: @account, id: params[:form_id])
  end

  def verify_hmac
    identifier = params[:identifier]
    signature  = params[:signature]

    if identifier.blank? || signature.blank?
      render plain: "Unauthorized: Missing HMAC credentials.", status: :unauthorized
      return
    end

    expected_signature = OpenSSL::HMAC.hexdigest("sha256", @form.secret, identifier)
    unless Rack::Utils.secure_compare(expected_signature, signature)
      render plain: "Unauthorized: Invalid HMAC signature.", status: :unauthorized
    end
  end
end
