# frozen_string_literal: true

class WidgetController < ApplicationController
  layout "widget"

  protect_from_forgery with: :null_session
  after_action :skip_session_cookie
  helper_method :customer_session_token

  before_action :set_widget
  around_action :set_sharding_context
  before_action :set_frame_ancestors
  before_action :identify_customer
  before_action :set_locale
  before_action :set_agents
  before_action :set_unread_count

  def index
    load_home_categories
  end

  def home
    load_home_categories
    respond_to do |format|
      format.turbo_stream do
        render(turbo_stream: turbo_stream.update("widget", partial: "widget/home"))
      end
    end
  end

  def messages
    if pre_chat_required_before_messages?
      respond_to do |format|
        format.turbo_stream do
          render(turbo_stream: turbo_stream.update("widget", partial: "widget/pre_chat_form"))
        end
      end
      return
    end

    if !@customer && !pre_chat_required?
      if @widget.anonymous_allowed?
        external_id = widget_customer_identifier || generate_anonymous_external_id
        @customer = Customers::CustomerCreator.call(
          account: @account,
          inbox: @inbox,
          external_id: external_id,
          params: { locale: I18n.locale }
        )
        @customer_inbox = @customer&.customer_inboxes&.find_by(inbox: @inbox)
      else
        return render(plain: "Anonymous chat is disabled.", status: :unauthorized)
      end
    end

    if !@customer && pre_chat_required?
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
                     .includes(:assignee, assignee: { avatar_attachment: :blob }, last_message: { attachments: { file_attachment: :blob } })
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
    return head(:not_found) unless @widget.help_center_enabled?

    @portal = @widget.portal
    base_query = @portal ? @portal.categories.active.everyone.includes(:translations, image_attachment: :blob) : HelpCenter::Category.none
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
    return head(:not_found) unless @widget.help_center_enabled?

    @portal = @widget.portal
    @category = @portal.categories.includes(:translations).find(params[:category_id])

    base_query = @category.articles.published.includes(:translations)

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
    return head(:unauthorized) unless @customer

    attachments_list = if params[:attachments].is_a?(Array)
      params[:attachments]
    elsif params[:attachments].respond_to?(:values)
      params[:attachments].values
    else
      []
    end

    conversation_data = parse_conversation_data(params[:conversation_data])
    conversation_data = @jwt_payload&.dig("conversation_data") || @jwt_payload&.dig(:conversation_data) if conversation_data.blank?
    conversation_data ||= {}

    @message = create_widget_message(
      content: params[:content],
      attachments: attachments_list,
      conversation_data: conversation_data
    )

    respond_to do |format|
      format.turbo_stream do
        if @message
          render(turbo_stream: append_widget_message_stream(@message))
        else
          head(:ok)
        end
      end
      format.html { head(:ok) }
    end
  end

  def article
    return head(:not_found) unless @widget.help_center_enabled?

    @portal = @widget.portal
    @category = @portal.categories.includes(:translations).find(params[:category_id])
    @article = @category.articles.published.includes(:translations).find_by(id: params[:article_id])

    return head(:not_found) unless @article

    respond_to do |format|
      format.turbo_stream do
        render(turbo_stream: turbo_stream.update("widget", partial: "widget/article"))
      end
    end
  end

  def search
    return head(:not_found) unless @widget.help_center_enabled?

    @portal = @widget.portal
    @query = (params[:query].presence || params[:q]).to_s.strip
    @active_tab = params[:tab].to_s == "categories" ? "categories" : "articles"
    unless @portal
      @articles = []
      @categories = []
      return render_search_results
    end

    articles_scope = @portal
      .articles
      .published
      .where(visibility: :everyone)
      .order(Arel.sql("help_center_articles.position ASC NULLS LAST, help_center_articles.updated_at DESC"))
      .includes(:translations, { categories: [ :translations, { image_attachment: :blob } ] }, primary_category: [ :translations, { image_attachment: :blob } ])

    categories_scope = @portal
      .categories
      .active
      .where(visibility: :everyone)
      .order(Arel.sql("help_center_categories.position ASC NULLS LAST, help_center_categories.updated_at DESC"))
      .includes(:translations, image_attachment: :blob)

    @articles_page = [ params[:page].to_i, 1 ].max
    @articles_per_page = 4
    @articles_visible_count = @articles_page * @articles_per_page

    if @query.present?
      articles_search = HelpCenter::Article.search(
        @query,
        where: {
          portal_id: @portal.id,
          status: "published",
          visibility: "everyone",
          "translations.locale": I18n.locale.to_s
        },
        includes: [ :translations, { categories: [ :translations, { image_attachment: :blob } ] }, primary_category: [ :translations, { image_attachment: :blob } ] ],
        fields: [ "translations.title^5", "translations.content" ],
        match: :word_start,
        page: 1,
        per_page: @articles_visible_count
      )

      categories_search = HelpCenter::Category.search(
        @query,
        where: {
          portal_id: @portal.id,
          status: "active",
          visibility: "everyone",
          "translations.locale": I18n.locale.to_s
        },
        includes: [ :translations, { image_attachment: :blob } ],
        fields: [ "translations.name^5", "translations.description" ],
        match: :word_start,
        limit: 5
      )

      @articles_total_count = articles_search.total_count
      @articles = articles_search
      @categories = categories_search
    else
      @articles_total_count = articles_scope.count
      @articles = articles_scope.limit(@articles_visible_count)
      @categories = categories_scope.limit(5)
    end

    @articles_next_page = @articles_page + 1 if @articles_total_count > @articles_visible_count
    @articles_previous_page = @articles_page - 1 if @articles_page > 1

    render_search_results
  end

  def create_customer
    customer_data = {
      email: params[:email],
      name: params[:name],
      data: {}
    }

    conversation_data = { title: nil, priority: nil, data: {} }
    message_content = nil

    if @pre_chat_custom_fields.any? && params[:custom_fields].present?
      @pre_chat_custom_fields.each do |field|
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

    external_id = widget_customer_identifier || customer_data[:email].presence || generate_anonymous_external_id

    @customer = Customers::CustomerCreator.call(
      account: @account,
      inbox: @inbox,
      external_id: external_id,
      email: customer_data[:email],
      params: {
        name: customer_data[:name],
        first_name: customer_data[:first_name] || customer_data[:name]&.split&.first,
        last_name: customer_data[:last_name] || customer_data[:name]&.split&.drop(1)&.join(" "),
        locale: I18n.locale
      }
    )

    @customer_inbox = @customer&.customer_inboxes&.find_by(inbox: @inbox)

    if @customer && customer_data[:data].present?
      @customer.data = @customer.data.merge(customer_data[:data])
      @customer.save
    end

    @pre_chat_conversation_data = conversation_data

    # If they mapped message.content, create the conversation and message immediately
    if message_content.present?
      @conversation = Channels::WebWidgets::ConversationCreator.call(
        web_widget_channel: @widget,
        contact_params: customer_contact_params,
        content: message_content,
        attachments: [],
        conversation_data: @pre_chat_conversation_data
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
      format.html { redirect_to(widget_messages_path(widget_route_params)) }
    end
  end

  def identify
    previous_customer = @customer

    if params[:identifier].present? || params[:email].present?
      if @widget.secure_identity_enforced?
        if params[:identifier].blank?
          return render(json: { error: "HMAC Identity is required" }, status: :unauthorized)
        end

        unless Channels::WebWidgets::IdentityVerifier.call(
          widget: @widget,
          identifier: params[:identifier],
          signature: params[:signature]
        )
          return render(json: { error: "Invalid signature" }, status: :unauthorized)
        end

        create_or_restore_customer(params[:identifier])
      elsif params[:identifier].present?
        if params[:signature].present?
          unless Channels::WebWidgets::IdentityVerifier.call(
            widget: @widget,
            identifier: params[:identifier],
            signature: params[:signature]
          )
            return render(json: { error: "Invalid signature" }, status: :unauthorized)
          end
        end

        create_or_restore_customer(params[:identifier])
      elsif params[:email].present?
        restore_customer_by_email(params[:email])
      end
    end

    if @customer.present?
      updates = {}
      updates[:name] = params[:name] if params[:name].present? && @customer.name.blank?
      updates[:email] = params[:email].downcase.strip if params[:email].present? && @customer.email.blank?
      @customer.update(updates) if updates.any?

      if previous_customer.present? && previous_customer.id != @customer.id && previous_customer.external_id&.start_with?("anon-")
        stitch_anonymous_conversations(previous_customer, @customer)
      end
    end

    mark_pre_chat_completed if @customer.present?

    find_or_set_conversation
    messages_query = @conversation&.messages&.global&.includes(:sender, attachments: { file_attachment: :blob })&.order(created_at: :desc) || Message.none
    @pagy, @messages = pagy(messages_query, items: 20)
    @messages = @messages.reverse

    respond_to do |format|
      format.turbo_stream do
        render(turbo_stream: turbo_stream.update("widget", partial: "widget/messages"))
      end
      format.json do
        render json: {
          success: true,
          customer_session_token: customer_session_token,
          customer: { id: @customer&.id, name: @customer&.name, email: @customer&.email }
        }
      end
      format.html { redirect_to(widget_messages_path) }
    end
  end

  private

  def stitch_anonymous_conversations(from_customer, to_customer)
    from_customer.conversations.where(inbox: @inbox).find_each do |conv|
      cm = conv.conversation_members.find_by(member: from_customer)
      if cm
        if conv.conversation_members.exists?(member: to_customer)
          cm.destroy
        else
          cm.update(member: to_customer)
        end
      end
      conv.messages.where(sender: from_customer).update_all(sender_id: to_customer.id)
    end
  end

  def append_widget_message_stream(message)
    turbo_stream.append("messages-list", partial: "widget/message", locals: { message: message })
  end

  def create_widget_message(content:, attachments:, conversation_data:)
    ShardRecord.transaction do
      @conversation = widget_message_conversation(conversation_data)
      @conversation.conversation_members.find_or_create_by!(conversation: @conversation, member: @customer, account: @account)

      message = Channels::WebWidgets::MessageCreator.call(
        account: @account,
        inbox: @inbox,
        conversation: @conversation,
        sender: @customer,
        content: content,
        attachments: attachments
      )

      Message.includes(:sender, attachments: { file_attachment: :blob }).find(message.id)
    end
  end

  def widget_message_conversation(conversation_data)
    reusable_conversation = reusable_widget_conversation(@conversation || latest_customer_conversation)
    return reusable_conversation if reusable_conversation

    conversation_data = conversation_data.to_h.with_indifferent_access
    @account.conversations.create!(
      inbox: @inbox,
      source: :web_widget,
      title: conversation_data[:title],
      priority: conversation_data[:priority].presence || "medium",
      data: conversation_data[:data] || {},
      locale: customer_contact_params[:locale],
      outbound_channel: @widget.fallback_channel
    )
  end

  def latest_customer_conversation
    @customer.conversations.where(inbox: @inbox, account: @account).order(created_at: :desc).first
  end

  def reusable_widget_conversation(conversation)
    return unless conversation

    if conversation.resolved?
      return unless widget_reopen_window_active?(conversation)

      conversation.update!(status: :active)
    end

    conversation
  end

  def widget_reopen_window_active?(conversation)
    return false if @inbox.reopen_window_seconds.to_i == 0
    return false if conversation.status_changed_at.blank?

    (Time.current - conversation.status_changed_at).to_i <= @inbox.reopen_window_seconds
  end

  def pre_chat_required?
    @widget.pre_chat_form_enabled? || @widget.pre_chat_form.present?
  end

  def pre_chat_required_before_messages?
    pre_chat_required? &&
      params[:conversation_id].blank? &&
      !pre_chat_completed?
  end

  def pre_chat_completed?
    @customer.present?
  end

  def mark_pre_chat_completed
    # Stateless: presence of @customer defines pre-chat completion
  end

  def render_search_results
    respond_to do |format|
      format.turbo_stream do
        render(turbo_stream: turbo_stream.update("help-results", partial: "widget/search_results"))
      end
      format.html do
        render(partial: "widget/search_results", layout: false)
      end
    end
  end

  def load_home_categories
    return unless @widget.help_center_enabled?

    @portal = @widget.portal
    @categories = @portal ? @portal.categories.active.everyone.includes(:translations, image_attachment: :blob).limit(6) : []
    # load_category_article_counts(@categories)
  end

  def set_sharding_context(&)
    @account ||= Account.find_by(id: widget_account_id)

    if @account
      @account.with_shard(&)
    else
      yield
    end
  end

  def set_widget
    @account ||= Account.find(widget_account_id)
    @widget = Channel::WebWidget
      .includes(:primary_inbox, :translations, pre_chat_form: [ :translations, { custom_field_resources: { custom_field: :translations } } ])
      .find_by!(account: @account, id: widget_id)
    @inbox = @widget.primary_inbox
    @pre_chat_custom_fields = ordered_pre_chat_custom_fields

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
  rescue ActiveRecord::RecordNotFound
    render(plain: "Widget not found", status: :not_found)
  end

  def ordered_pre_chat_custom_fields
    return [] unless @widget.pre_chat_form

    @widget.pre_chat_form.custom_field_resources
      .sort_by { |resource| [ resource.position || Float::INFINITY, resource.created_at || Time.zone.at(0) ] }
      .filter_map(&:custom_field)
  end

  def set_frame_ancestors
    # Remove Rails default X-Frame-Options to allow embedding
    response.headers.delete("X-Frame-Options")

    allowed_domains = [ "'self'" ]
    allowed_domains += @widget.allowed_hosts if @widget.allowed_hosts.present?

    # Allow rendering in the dashboard for live preview
    if params[:preview] == "true" && ENV["DESKBOLIC_URL"].present?
      allowed_domains << ENV.fetch("DESKBOLIC_URL", nil)
    end

    response.headers["Content-Security-Policy"] = "frame-ancestors #{allowed_domains.join(' ')}"
  end

  def set_agents
    find_or_set_conversation
    assignee = @conversation&.assignee

    @all_agents = @inbox.users.includes(avatar_attachment: :blob).limit(3)

    @agents = assignee ? [ assignee ] : @all_agents
  end

  def identify_customer
    restore_customer
    return if @customer

    if @widget.secure_identity_enforced?
      if params[:identifier].blank?
        return render(json: { error: "HMAC Identity is required" }, status: :unauthorized)
      end

      unless Channels::WebWidgets::IdentityVerifier.call(
        widget: @widget,
        identifier: params[:identifier],
        signature: params[:signature]
      )
        return render(json: { error: "Invalid signature" }, status: :unauthorized)
      end

      create_or_restore_customer(params[:identifier])
    elsif params[:identifier].present?
      if params[:signature].present?
        unless Channels::WebWidgets::IdentityVerifier.call(
          widget: @widget,
          identifier: params[:identifier],
          signature: params[:signature]
        )
          return render(json: { error: "Invalid signature" }, status: :unauthorized)
        end
      end

      create_or_restore_customer(params[:identifier])
    elsif params[:email].present?
      restore_customer_by_email(params[:email])
    end
  end

  def restore_customer_by_email(email)
    existing_customer = @account.customers.find_by(email: email.to_s.downcase.strip)
    return unless existing_customer

    @customer = existing_customer
    @customer_inbox = @inbox.customer_inboxes.find_by(customer_id: @customer.id) ||
                      Customers::CustomerInboxCreator.call(account: @account, customer: @customer, inbox: @inbox)
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
    @customer
  end

  def find_or_set_conversation
    return if @conversation

    if params[:conversation_id].present?
      @conversation = @customer&.conversations&.find_by(id: params[:conversation_id], inbox: @inbox)
    else
      @conversation = @customer&.conversations&.where(inbox: @inbox)&.active&.first
      if @conversation.nil? && @customer.present?
        latest = latest_customer_conversation
        @conversation = latest if latest && widget_reopen_window_active?(latest)
      end
    end
  end

  def customer_contact_params
    {
      external_id: @customer_inbox&.external_id || widget_customer_identifier || @customer&.external_id,
      email: @customer&.email || params[:email],
      name: @customer&.name || params[:name],
      first_name: @customer&.first_name || params[:first_name],
      last_name: @customer&.last_name || params[:last_name],
      avatar_url: params[:avatar_url],
      locale: I18n.locale
    }
  end

  def set_locale
    I18n.locale = params[:locale] || @widget.default_locale || I18n.default_locale
  end

  def restore_customer
    customer_session_token = request.headers["X-Customer-Session-Token"].presence ||
                             params[:customer_session_token].presence
    return if customer_session_token.blank?

    payload = JwtService.decode(customer_session_token)
    return unless valid_resume_payload?(payload)

    @jwt_payload = payload
    @customer = @account.customers.find_by(id: payload[:customer_id])
    return unless @customer

    @customer_inbox = @inbox.customer_inboxes.find_by(customer_id: @customer.id) ||
                      Customers::CustomerInboxCreator.call(account: @account, customer: @customer, inbox: @inbox)

    if @customer.locale != I18n.locale.to_s
      @customer.update(locale: I18n.locale)
    end
  end

  def valid_resume_payload?(payload)
    payload.present? &&
      payload[:purpose] == "widget_customer_resume" &&
      payload[:account_id].to_s == @account.id.to_s &&
      payload[:widget_id].to_s == @widget.id.to_s &&
      payload[:inbox_id].to_s == @inbox.id.to_s &&
      payload[:customer_id].present?
  end

  def widget_customer_identifier
    params[:identifier].presence || @customer&.external_id
  end

  def widget_account_id
    params[:account_id].presence
  end

  def widget_id
    params[:widget_id].presence
  end

  def customer_session_token
    return unless @customer && @customer_inbox

    payload = {
      purpose: "widget_customer_resume",
      account_id: @account.id,
      widget_id: @widget.id,
      inbox_id: @inbox.id,
      customer_id: @customer.id
    }
    payload[:conversation_data] = @pre_chat_conversation_data if @pre_chat_conversation_data.present?

    @customer_session_token ||= JwtService.encode(payload, expiry: 30.days)
  end

  def parse_conversation_data(data)
    return nil if data.blank?
    if data.is_a?(String)
      JSON.parse(data).with_indifferent_access rescue nil
    elsif data.respond_to?(:to_unsafe_h)
      data.to_unsafe_h.with_indifferent_access
    elsif data.is_a?(Hash)
      data.with_indifferent_access
    end
  end

  def skip_session_cookie
    request.session_options[:skip] = true
  end

  def generate_anonymous_external_id
    loop do
      candidate = "anon-#{SecureRandom.uuid}"
      break candidate unless @account.customers.exists?(external_id: candidate) ||
                             @inbox.customer_inboxes.exists?(external_id: candidate)
    end
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
