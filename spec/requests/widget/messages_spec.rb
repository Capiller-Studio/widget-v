# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget::Messages', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, reopen_window_seconds: 86400) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, flags: 1) # flag 1: anonymous_allowed
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'GET /w/:account_id/:widget_id/messages' do
    it 'creates an anonymous customer when allowed and renders messages Turbo Stream' do
      account.with_shard do
        get widget_messages_path(account_id: account.id, widget_id: widget.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('turbo-stream action="update" target="widget"')
        expect(response.body).to include('data-widget-customer-session-token-value')
        anon_customer = account.customers.where("external_id LIKE ?", "anon-%").last
        expect(anon_customer).to be_present
      end
    end

    it 'renders pre-chat form when pre-chat is required and not completed' do
      account.with_shard do
        pre_chat = create(:channel_contact_form, account: account)
        widget.update!(pre_chat_form: pre_chat)

        get widget_messages_path(account_id: account.id, widget_id: widget.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('pre_chat')
      end
    end

    it 'renders a linked pre-chat contact form with ordered custom fields' do
      account.with_shard do
        pre_chat = create(:channel_contact_form, account: account)
        department_field = create(:custom_field, account: account, key: 'department')
        create(:custom_field_resource, resource: pre_chat, custom_field: department_field, position: 1)
        widget.update!(pre_chat_form: pre_chat)

        get widget_messages_path(account_id: account.id, widget_id: widget.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('custom_fields[department]')
      end
    end

    it 'returns 401 unauthorized when anonymous chat is disabled and visitor is unauthenticated' do
      account.with_shard do
        widget.update!(flags: 0) # anonymous_allowed = false

        get widget_messages_path(account_id: account.id, widget_id: widget.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to include('Anonymous chat is disabled')
      end
    end

    it 'supports pagination of message history' do
      account.with_shard do
        customer = create(:customer, account: account)
        create(:customer_inbox, customer: customer, inbox: inbox)
        conversation = create(:conversation, account: account, inbox: inbox)
        conversation.conversation_members.create!(member: customer, account: account)
        25.times do |i|
          create(:message, account: account, inbox: inbox, conversation: conversation, sender: customer, content: "Message #{i}")
        end

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        get widget_messages_path(account_id: account.id, widget_id: widget.id, customer_session_token: token, page: 2), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'POST /w/:account_id/:widget_id/messages' do
    it 'creates a message from the authenticated customer and appends to stream' do
      account.with_shard do
        customer = create(:customer, account: account)
        create(:customer_inbox, customer: customer, inbox: inbox)

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        expect do
          post widget_create_message_path(account_id: account.id, widget_id: widget.id, customer_session_token: token),
               params: { content: 'Hello team!' },
               headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
        end.to change(Message, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('turbo-stream action="append" target="messages-list"')
        expect(response.body).to include('Hello team!')
      end
    end

    it 'creates a message using X-Customer-Session-Token header and appends to stream' do
      account.with_shard do
        customer = create(:customer, account: account)
        create(:customer_inbox, customer: customer, inbox: inbox)

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        expect do
          post widget_create_message_path(account_id: account.id, widget_id: widget.id),
               params: { content: 'Message via header token' },
               headers: {
                 'Accept' => 'text/vnd.turbo-stream.html',
                 'X-Customer-Session-Token' => token
               }
        end.to change(Message, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Message via header token')
      end
    end

    it 'returns 401 unauthorized when unauthenticated customer tries to post message' do
      account.with_shard do
        widget.update!(flags: 0)

        post widget_create_message_path(account_id: account.id, widget_id: widget.id),
             params: { content: 'Unauthorized message' },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'Sessionless & Cross-Origin Persistence' do
    it 'bypasses pre-chat form when customer is restored via JWT token with empty session' do
      account.with_shard do
        pre_chat = create(:channel_contact_form, account: account)
        widget.update!(pre_chat_form: pre_chat)

        customer = create(:customer, account: account, name: 'Restored User')
        create(:customer_inbox, customer: customer, inbox: inbox)

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        get widget_messages_path(account_id: account.id, widget_id: widget.id, customer_session_token: token),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('pre-chat-fields')
        expect(response.body).to include('main-content')
      end
    end

    it 'bypasses pre-chat form when customer is restored via X-Customer-Session-Token header' do
      account.with_shard do
        pre_chat = create(:channel_contact_form, account: account)
        widget.update!(pre_chat_form: pre_chat)

        customer = create(:customer, account: account, name: 'Header Restored User')
        create(:customer_inbox, customer: customer, inbox: inbox)

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        get widget_messages_path(account_id: account.id, widget_id: widget.id),
            headers: {
              'Accept' => 'text/vnd.turbo-stream.html',
              'X-Customer-Session-Token' => token
            }

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('pre-chat-fields')
        expect(response.body).to include('main-content')
        # Back button is a link tag preventing form action stripping
        expect(response.body).to match(/<a[^>]+class="widget-chat-back"[^>]+href="[^"]*home\.turbo_stream/)
      end
    end

    it 'reuses resolved conversation within reopen window' do
      account.with_shard do
        customer = create(:customer, account: account)
        conversation = create(:conversation, account: account, inbox: inbox, status: :resolved, status_changed_at: 10.minutes.ago)
        conversation.conversation_members.create!(member: customer, account: account)
        create(:message, account: account, inbox: inbox, conversation: conversation, sender: customer, content: 'Earlier chat')

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        get widget_messages_path(account_id: account.id, widget_id: widget.id, customer_session_token: token),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Earlier chat')
      end
    end
  end
end
