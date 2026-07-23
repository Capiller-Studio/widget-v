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
    if @form.spam_protection_enabled? && params[:nickname].present?
      redirect_to contact_form_redirect_path, alert: I18n.t("contact_form.failure", default: "Something went wrong. Please try again.")
      return
    end

    form_params = params.except(:action, :controller, :account_id, :form_id, :locale, :signature, :identifier, :attachments, :nickname).to_unsafe_h
    attachments = @form.allow_attachments? ? Array(params[:attachments]).reject(&:blank?) : []

    conversation = Channels::ContactForms::ConversationCreator.call(
      contact_form_channel: @form,
      form_params: form_params,
      attachments: attachments
    )

    if conversation
      success_message = @form.success_message.presence || I18n.t(@form.configurations["success_message_i18n_key"] || "contact_form.success", default: "Thank you! Your message has been received.")
      redirect_to contact_form_redirect_path, notice: success_message
    else
      failure_message = I18n.t("contact_form.failure", default: "Something went wrong. Please try again.")
      redirect_to contact_form_redirect_path, alert: failure_message
    end
  rescue StandardError => e
    Rails.logger.error("Contact form submission failed: #{e.class}: #{e.message}")
    failure_message = I18n.t("contact_form.failure", default: "Something went wrong. Please try again.")
    redirect_to contact_form_redirect_path, alert: failure_message
  end

  private

  def set_locale
    I18n.locale = params[:locale] || I18n.default_locale
  end

  def set_form
    @account = Account.find(params[:account_id])
    @form = Channel::ContactForm.includes(:translations).find_by!(account: @account, id: params[:form_id])
  end

  def contact_form_redirect_path
    contact_form_entry_path(
      account_id: @account.id,
      form_id: @form.id,
      locale: I18n.locale,
      identifier: params[:identifier].presence,
      signature: params[:signature].presence,
      email: params[:email].presence,
      name: params[:name].presence
    )
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
