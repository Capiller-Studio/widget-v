# frozen_string_literal: true

class WidgetController < ApplicationController
  layout "widget"

  before_action :set_widget
  before_action :set_frame_ancestors
  before_action :identify_customer
  before_action :set_locale
  before_action :set_agents

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
        external_id = "anon-#{SecureRandom.hex(8)}"
        @customer = Customers::CustomerCreator.call(
          account: @account,
          inbox: @inbox,
          external_id: external_id
        )
        @customer_inbox = @customer&.customer_inboxes&.find_by(inbox: @inbox)
        session[:customer_id] = @customer.id
        session[:customer_external_id] = @customer_inbox&.external_id
      else
        return render plain: "Anonymous chat is disabled.", status: :unauthorized
      end
    end

    find_or_set_conversation
    messages_query = @conversation&.messages&.includes(:attachments, sender: { avatar_attachment: :blob })&.order(created_at: :desc) || Message.none
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
    base_query = @customer ? @customer.conversations.where(inbox: @inbox).order(updated_at: :desc) : Conversation.none
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
    external_id = "anon-#{SecureRandom.hex(8)}"
    
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

    session[:customer_id] = @customer.id
    session[:customer_external_id] = @customer_inbox&.external_id
    
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
    messages_query = @conversation&.messages&.includes(:attachments, sender: { avatar_attachment: :blob })&.order(created_at: :desc) || Message.none
    @pagy, @messages = pagy(messages_query, items: 20)
    @messages = @messages.reverse

    respond_to do |format|
      format.turbo_stream do
        render(turbo_stream: turbo_stream.update("widget", partial: "widget/messages"))
      end
      format.html { redirect_to messages_path }
    end
  end

  private

  def set_widget
    @account = Account.find(params[:account_id] || session[:account_id])
    @widget = Channel::WebWidget.includes(:primary_inbox).find_by!(account: @account, id: params[:widget_id] || session[:widget_id])
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
    # 1. Restore from session
    if session[:customer_id].present? && session[:widget_id] == @widget.id
      @customer = Customer.find_by(id: session[:customer_id])
      @customer_inbox = @customer&.customer_inboxes&.find_by(inbox: @inbox)
    end

    return if @customer

    if @widget.secure_identity_enforced? && params[:identifier].blank?
      return render json: { error: "HMAC Identity is required" }, status: :unauthorized
    end

    # 2. HMAC identification (optional unless enforced)
    return unless params[:identifier].present?

    unless Channels::WebWidgets::IdentityVerifier.call(
      widget: @widget,
      identifier: params[:identifier],
      signature: params[:signature]
    )
      return render json: { error: "Invalid signature" }, status: :unauthorized
    end

    @customer = Customers::CustomerCreator.call(
      account: @account,
      inbox: @inbox,
      external_id: params[:identifier],
      email: params[:email],
      params: {
        name: params[:name],
        first_name: params[:first_name],
        last_name: params[:last_name],
        avatar_url: params[:avatar_url]
      }
    )

    @customer_inbox = @customer&.customer_inboxes&.find_by(inbox: @inbox)
    session[:customer_id] = @customer.id
    session[:customer_external_id] = @customer_inbox&.external_id
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
      external_id: @customer_inbox&.external_id || session[:customer_external_id] || params[:identifier] || @customer&.external_id,
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

  def default_url_options
    { locale: I18n.locale }
  end
end
