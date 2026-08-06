# frozen_string_literal: true

class WidgetController < ApplicationController
  layout "widget"

  protect_from_forgery with: :null_session
  helper_method :customer_session_token

  before_action :set_widget
  around_action :set_sharding_context
  before_action :set_frame_ancestors
  before_action :identify_customer
  before_action :set_locale
  before_action :set_agents
  before_action :set_unread_count

  def index; end

  def home
    respond_to do |format|
      format.turbo_stream do
        render(turbo_stream: turbo_stream.update("widget", partial: "widget/home"))
      end
    end
  end

  def messages
    if !@customer && !@widget.pre_chat_form_enabled?
      if @widget.anonymous_allowed?
        external_id = widget_customer_identifier || "anon-#{SecureRandom.hex(8)}"
        @customer = Customers::CustomerCreator.call(
          account: @account,
          inbox: @inbox,
          external_id: external_id
        )
        @customer_inbox = @customer&.customer_inboxes&.find_by(inbox: @inbox)
        store_customer_in_session
      else
        return render plain: "Anonymous chat is disabled.", status: :unauthorized
      end
    end

    if !@customer && @widget.pre_chat_form_enabled?
      respond_to do |format|
        format.turbo_stream do
          render(turbo_stream: turbo_stream.update("widget", partial: "widget/pre_chat_form"))
        end
      end
      return
    end

    find_or_set_conversation
    messages_query = @conversation&.messages&.global&.includes(:sender, attachments: { file_attachment: :blob })&.order(created_at: :desc) || Message.none
    @pagy, @messages = pagy(messages_query, items: 20)
    
    # We ordered by desc for pagy, so reverse to show in chronological order in UI
    @messages = @messages.reverse

    respond_to do |format|
      format.turbo_stream do
        if params[:page].present?
          render(turbo_stream: turbo_stream.prepend("messages-list", partial: "widget/message", collection: @messages) + turbo_stream.replace("messages_pager", partial: "widget/messages_pager"))
        else
          render(turbo_stream: turbo_stream.update("widget", partial: "widget/messages"))
        end
      end
    end
  end

  def conversations
    base_query = if @customer
                   @customer.conversations
                     .where(account: @account, inbox: @inbox)
                     .includes(last_message: { attachments: { file_attachment: :blob } })
                     .order(updated_at: :desc)
                 else
                   Conversation.none
                 end
    @pagy, @conversations = pagy(base_query, items: 10)

    respond_to do |format|
      format.turbo_stream do
        if params[:page].present?
          render(turbo_stream: turbo_stream.append("conversations-list", partial: "widget/conversation_item", collection: @conversations, as: :conversation) + turbo_stream.replace("conversations_pager", partial: "widget/conversations_pager"))
        else
          render(turbo_stream: turbo_stream.update("widget", partial: "widget/conversations"))
        end
      end
    end
  end

  def help
    return head :not_found unless @widget.help_center_enabled?

    @portal = @widget.portal
    base_query = @portal ? @portal.categories.active : HelpCenter::Category.none
    @pagy, @categories = pagy(base_query, items: 10)

    respond_to do |format|
      format.turbo_stream do
        if params[:page].present?
          render(turbo_stream: turbo_stream.append("categories-list", partial: "widget/category_item", collection: @categories, as: :category) + turbo_stream.replace("categories_pager", partial: "widget/categories_pager"))
        else
          render(turbo_stream: turbo_stream.update("widget", partial: "widget/help"))
        end
      end
    end
  end

  def category
    return head :not_found unless @widget.help_center_enabled?

    @portal = @widget.portal
    @category = @portal.categories.find(params[:category_id])
    
    # Manually query HelpCenter::Article via CategoryResource joins since `has_many :articles` isn't strictly defined on Category
    base_query = HelpCenter::Article.joins(
      "INNER JOIN help_center_category_resources ON help_center_category_resources.resource_id = help_center_articles.id AND help_center_category_resources.resource_type = 'HelpCenter::Article'"
    ).where(help_center_category_resources: { category_id: @category.id }).published
    
    @pagy, @articles = pagy(base_query, items: 10)
    
    respond_to do |format|
      format.turbo_stream do
        if params[:page].present?
          render(turbo_stream: turbo_stream.append("articles-list", partial: "widget/article_item", collection: @articles, as: :article) + turbo_stream.replace("articles_pager", partial: "widget/articles_pager"))
        else
          render(turbo_stream: turbo_stream.update("widget", partial: "widget/category"))
        end
      end
    end
  end

  def create_message
    return head :unauthorized unless @customer

    @conversation = Channels::WebWidgets::ConversationCreator.call(
      web_widget_channel: @widget,
      contact_params: customer_contact_params,
      content: params[:content],
      attachments: params[:attachments]&.values || [],
      conversation_data: session[:pre_chat_conversation_data] || {}
    )
    
    # Clear it from session so we don't accidentally reuse it for subsequent conversations
    session.delete(:pre_chat_conversation_data)

    head :ok
  end

  def search
    return head :not_found unless @widget.help_center_enabled?

    @portal = @widget.portal
    @articles = HelpCenter::ArticleSearcher.call(
      query: params[:q],
      account: @account,
      portal: @portal,
      locale: I18n.locale
    )

    respond_to do |format|
      format.turbo_stream do
        render(turbo_stream: turbo_stream.update("help-results", partial: "widget/search_results"))
      end
    end
  end

  def create_customer
    customer_data = {
      email: params[:email],
      name: params[:name],
      data: {}
    }
    
    conversation_data = { title: nil, priority: nil, data: {} }
    message_content = nil

    if @widget.pre_chat_form&.custom_fields&.any? && params[:custom_fields].present?
      @widget.pre_chat_form.custom_fields.each do |field|
        value = params[:custom_fields][field.key]
        next if value.blank?

        if field.mapped_to.present?
          case field.mapped_to
          when "customer.name"       then customer_data[:name] = value
          when "customer.first_name" then customer_data[:first_name] = value
          when "customer.last_name"  then customer_data[:last_name] = value
          when "customer.email"      then customer_data[:email] = value
          when "conversation.title"  then conversation_data[:title] = value
          when "conversation.priority" then conversation_data[:priority] = value
          when "message.content"     then message_content = value
          end
        elsif field.entity_type == "customer"
          customer_data[:data][field.key] = value
        elsif field.entity_type == "conversation"
          conversation_data[:data][field.key] = value
        end
      end
    end

    external_id = widget_customer_identifier || customer_data[:email].presence || "anon-#{SecureRandom.hex(8)}"

    @customer = Customers::CustomerCreator.call(
      account: @account,
      inbox: @inbox,
      external_id: external_id,
      email: customer_data[:email],
      params: {
        name: customer_data[:name],
        first_name: customer_data[:first_name] || customer_data[:name]&.split(" ")&.first,
        last_name: customer_data[:last_name] || customer_data[:name]&.split(" ")&.drop(1)&.join(" ")
      }
    )

    @customer_inbox = @customer&.customer_inboxes&.find_by(inbox: @inbox)
    
    if @customer && customer_data[:data].present?
      @customer.data = @customer.data.merge(customer_data[:data])
      @customer.save
    end

    store_customer_in_session
    
    session[:pre_chat_conversation_data] = conversation_data

    # If they mapped message.content, create the conversation and message immediately
    if message_content.present?
      @conversation = Channels::WebWidgets::ConversationCreator.call(
        web_widget_channel: @widget,
        contact_params: customer_contact_params,
        content: message_content,
        attachments: []
      )
    end

    # After creating the customer, redirect to messages view
    find_or_set_conversation
    messages_query = @conversation&.messages&.includes(:sender, attachments: { file_attachment: :blob })&.order(created_at: :desc) || Message.none
    @pagy, @messages = pagy(messages_query, items: 20)
    @messages = @messages.reverse

    respond_to do |format|
      format.turbo_stream do
        render(turbo_stream: turbo_stream.update("widget", partial: "widget/messages"))
      end
      format.html { redirect_to widget_messages_path(widget_route_params) }
    end
  end

  private

  def set_sharding_context(&block)
    @account ||= Account.find_by(id: widget_account_id)

    if @account
      @account.with_shard(&block)
    else
      yield
    end
  end

  def set_widget
    @account ||= Account.find(widget_account_id)
    @widget = Channel::WebWidget.includes(:primary_inbox).find_by!(account: @account, id: widget_id)
    @inbox = @widget.primary_inbox

    if @widget&.primary_inbox&.business_hour_group_id.present?
      @is_offline = !AssignmentPolicies::BusinessHoursChecker.call(
        business_hour_group: @widget.primary_inbox.business_hour_group,
        time: Time.current
      )
    else
      @is_offline = false
    end

    return render(plain: "Widget not configured", status: :service_unavailable) unless @inbox

    # @agents = @inbox.users.includes(avatar_attachment: :blob).limit(3)

    session[:account_id] = @account.id
    session[:widget_id] = @widget.id
  rescue ActiveRecord::RecordNotFound
    render plain: "Widget not found", status: :not_found
  end

  def set_frame_ancestors
    # Remove Rails default X-Frame-Options to allow embedding
    response.headers.delete("X-Frame-Options")
    
    allowed_domains = ["'self'"]
    allowed_domains << @widget.website_url if @widget.website_url.present?
    
    # Allow rendering in the dashboard for live preview
    if params[:preview] == 'true' && ENV['DESKBOLIC_URL'].present?
      allowed_domains << ENV['DESKBOLIC_URL']
    end
    
    response.headers["Content-Security-Policy"] = "frame-ancestors #{allowed_domains.join(' ')}"
  end

  def set_agents
    find_or_set_conversation
    assignee = @conversation&.assignee

    @all_agents = @inbox.users.includes(avatar_attachment: :blob).limit(3)

    @agents = assignee ? [assignee] : @all_agents
  end

  def identify_customer
    restore_customer
    return if @customer

    if @widget.secure_identity_enforced? && params[:identifier].blank?
      return render json: { error: "HMAC Identity is required" }, status: :unauthorized
    end

    if params[:identifier].present?
      unless Channels::WebWidgets::IdentityVerifier.call(
        widget: @widget,
        identifier: params[:identifier],
        signature: params[:signature]
      )
        return render json: { error: "Invalid signature" }, status: :unauthorized
      end

      create_or_restore_customer(params[:identifier])
      return
    end
  end

  def create_or_restore_customer(external_id)
    @customer = Customers::CustomerCreator.call(
      account: @account,
      inbox: @inbox,
      external_id: external_id,
      email: params[:email],
      params: {
        name: params[:name],
        first_name: params[:first_name],
        last_name: params[:last_name],
        avatar_url: params[:avatar_url]
      }
    )

    @customer_inbox = @customer&.customer_inboxes&.find_by(inbox: @inbox)
    store_customer_in_session
    @customer
  end

  def find_or_set_conversation
    return if @conversation

    if params[:conversation_id].present?
      @conversation = @customer&.conversations&.find_by(id: params[:conversation_id], inbox: @inbox)
    else
      @conversation = @customer&.conversations&.where(inbox: @inbox)&.active&.first
    end
  end

  def customer_contact_params
    {
      external_id: @customer_inbox&.external_id || widget_customer_identifier || session[:customer_external_id] || @customer&.external_id,
      email: @customer&.email || params[:email],
      name: @customer&.name || params[:name],
      first_name: @customer&.first_name || params[:first_name],
      last_name: @customer&.last_name || params[:last_name],
      avatar_url: params[:avatar_url]
    }
  end

  def set_locale
    I18n.locale = params[:locale] || @widget.default_locale || I18n.default_locale
  end

  def restore_customer
    customer_session_token = params[:customer_session_token].presence
    customer_session_token ||= session[:customer_session_token] if session[:widget_id] == @widget.id
    return unless customer_session_token.present?

    payload = JwtService.decode(customer_session_token)
    return unless valid_resume_payload?(payload)

    @customer_inbox = @inbox.customer_inboxes
      .joins(:customer)
      .includes(:customer)
      .where(customers: { account_id: @account.id })
      .find_by(customer_id: payload[:customer_id])
    @customer = @customer_inbox&.customer
  end

  def valid_resume_payload?(payload)
    payload.present? &&
      payload[:purpose] == "widget_customer_resume" &&
      payload[:account_id].to_s == @account.id.to_s &&
      payload[:widget_id].to_s == @widget.id.to_s &&
      payload[:inbox_id].to_s == @inbox.id.to_s &&
      payload[:customer_id].present?
  end

  def store_customer_in_session
    return unless @customer

    session[:customer_id] = @customer.id
    session[:customer_external_id] = @customer_inbox&.external_id
    session[:customer_session_token] = customer_session_token
  end

  def widget_customer_identifier
    params[:identifier].presence || @customer&.external_id
  end

  def widget_account_id
    params[:account_id].presence || session[:account_id]
  end

  def widget_id
    params[:widget_id].presence || session[:widget_id]
  end

  def customer_session_token
    return unless @customer && @customer_inbox

    @customer_session_token ||= JwtService.encode(
      {
        purpose: "widget_customer_resume",
        account_id: @account.id,
        widget_id: @widget.id,
        inbox_id: @inbox.id,
        customer_id: @customer.id
      },
      expiry: 30.days
    )
  end

  def set_unread_count
    if @customer && @account && @inbox
      counts = UnreadCounts::Current.call(member: @customer, account_id: @account.id)
      @unread_count = counts[:inboxes][@inbox.id.to_s].to_i
    else
      @unread_count = 0
    end
  end

  def default_url_options
    options = { locale: I18n.locale }

    options[:account_id] = @account.id if @account
    options[:widget_id] = @widget.id if @widget
    options[:customer_session_token] = customer_session_token if @customer

    options
  end
end
