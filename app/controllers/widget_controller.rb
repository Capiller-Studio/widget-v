# frozen_string_literal: true

class WidgetController < ApplicationController
  layout "widget"

  before_action :set_widget
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
      attachments: params[:attachments]&.values || []
    )

    head :ok
  end

  def search
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

    @customer = Customers::CustomerCreator.call(
      account: @account,
      inbox: @inbox,
      external_id: external_id,
      email: params[:email],
      params: {
        name: params[:name],
        first_name: params[:name]&.split(" ")&.first,
        last_name: params[:name]&.split(" ")&.drop(1)&.join(" ")
      }
    )

    @customer_inbox = @customer&.customer_inboxes&.find_by(inbox: @inbox)
    session[:customer_id] = @customer.id
    session[:customer_external_id] = @customer_inbox&.external_id

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

    return render(plain: "Widget not configured", status: :service_unavailable) unless @inbox

    # @agents = @inbox.users.includes(avatar_attachment: :blob).limit(3)

    session[:account_id] = @account.id
    session[:widget_id] = @widget.id
  rescue ActiveRecord::RecordNotFound
    render plain: "Widget not found", status: :not_found
  end

  def set_agents
    find_or_set_conversation
    assignee = @conversation&.assignee

    @agents = assignee ? [assignee] : @inbox.users.includes(avatar_attachment: :blob).limit(3)
  end

  def identify_customer
    # 1. Restore from session
    if session[:customer_id].present? && session[:widget_id] == @widget.id
      @customer = Customer.find_by(id: session[:customer_id])
      @customer_inbox = @customer&.customer_inboxes&.find_by(inbox: @inbox)
    end

    return if @customer

    # 2. HMAC identification (required)
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
    I18n.locale = params[:locale] || @widget.configurations&.dig("default_locale") || I18n.default_locale
  end

  def default_url_options
    { locale: I18n.locale }
  end
end
