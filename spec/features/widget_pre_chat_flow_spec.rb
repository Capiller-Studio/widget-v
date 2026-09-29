# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget Pre-Chat Form Flow', type: :feature do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, name: 'Support Widget')
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  before do
    page.driver.header 'Accept', 'text/vnd.turbo-stream.html'
  end

  describe 'Visitor journey through pre-chat form' do
    it 'renders pre-chat form with default and custom fields when pre-chat is required' do
      account.with_shard do
        subject_field = account.custom_fields.find_by(key: 'subject')
        priority_field = account.custom_fields.find_by(key: 'priority')
        pre_chat = create(:channel_contact_form, account: account, title: 'Welcome to Support', subtitle: 'Please tell us about your issue')
        create(:custom_field_resource, resource: pre_chat, custom_field: subject_field, position: 1)
        create(:custom_field_resource, resource: pre_chat, custom_field: priority_field, position: 2)
        widget.update!(pre_chat_form: pre_chat)

        visit widget_messages_path(account_id: account.id, widget_id: widget.id)

        expect(page.status_code).to eq(200)
        expect(page.body).to include('turbo-stream action="update" target="widget"')
        expect(page.body).to include('Welcome to Support')
        expect(page.body).to include('Please tell us about your issue')
        expect(page.body).to include('custom_field_subject')
        expect(page.body).to include('custom_field_priority')
        expect(page.body).to include('pre-chat-form')
      end
    end

    it 'submits pre-chat form, creates customer, and establishes customer session token in DOM' do
      account.with_shard do
        pre_chat = create(:channel_contact_form, account: account)
        widget.update!(pre_chat_form: pre_chat)

        page.driver.post widget_create_customer_path(account_id: account.id, widget_id: widget.id), {
          name: 'Morgan Freeman',
          email: 'morgan@example.com'
        }

        expect(page.status_code).to eq(200)
        created_customer = account.customers.find_by(email: 'morgan@example.com')
        expect(created_customer).to be_present
        expect(created_customer.name).to eq('Morgan Freeman')

        expect(page.body).to include('data-controller="widget"')
        expect(page.body).to include('data-widget-customer-session-token-value')
      end
    end

    it 'submits pre-chat form with custom conversation fields and preserves them into first sent message without cookies' do
      account.with_shard do
        subject_field = account.custom_fields.find_by(key: 'subject')
        priority_field = account.custom_fields.find_by(key: 'priority')
        pre_chat = create(:channel_contact_form, account: account)
        create(:custom_field_resource, resource: pre_chat, custom_field: subject_field, position: 1)
        create(:custom_field_resource, resource: pre_chat, custom_field: priority_field, position: 2)
        widget.update!(pre_chat_form: pre_chat)

        page.driver.post widget_create_customer_path(account_id: account.id, widget_id: widget.id), {
          name: 'Morgan Freeman',
          email: 'morgan@example.com',
          custom_fields: {
            'subject' => 'Enterprise Billing Inquiry',
            'priority' => 'urgent'
          }
        }

        expect(page.status_code).to eq(200)
        token_match = page.body.match(/data-widget-customer-session-token-value="([^"]+)"/)
        expect(token_match).to be_present
        token = token_match[1]

        # First message sent by visitor carrying the customer session token
        page.driver.header 'X-Customer-Session-Token', token
        page.driver.post widget_create_message_path(account_id: account.id, widget_id: widget.id), {
          content: 'I need an enterprise invoice generated immediately'
        }

        expect(page.status_code).to eq(200)

        # Confirm conversation received mapped pre-chat attributes
        conv = account.conversations.order(created_at: :desc).first
        expect(conv).to be_present
        expect(conv.title).to eq('Enterprise Billing Inquiry')
        expect(conv.priority).to eq('urgent')
        expect(conv.messages.first.content).to eq('I need an enterprise invoice generated immediately')
      end
    end

    it 'creates conversation immediately when message field is included in pre-chat form' do
      account.with_shard do
        msg_field = account.custom_fields.find_by(key: 'message')
        pre_chat = create(:channel_contact_form, account: account)
        create(:custom_field_resource, resource: pre_chat, custom_field: msg_field, position: 1)
        widget.update!(pre_chat_form: pre_chat)

        page.driver.post widget_create_customer_path(account_id: account.id, widget_id: widget.id), {
          name: 'Sarah Connor',
          email: 'sarah@resistance.org',
          custom_fields: {
            'message' => 'The machines are coming, send help!'
          }
        }

        expect(page.status_code).to eq(200)
        customer = account.customers.find_by(email: 'sarah@resistance.org')
        expect(customer).to be_present

        conv = customer.conversations.first
        expect(conv).to be_present
        expect(conv.messages.first.content).to eq('The machines are coming, send help!')
      end
    end

    it 'preserves customer session and conversations across full navigation cycle (messages -> home -> conversations)' do
      account.with_shard do
        msg_field = account.custom_fields.find_by(key: 'message')
        pre_chat = create(:channel_contact_form, account: account)
        create(:custom_field_resource, resource: pre_chat, custom_field: msg_field, position: 1)
        widget.update!(pre_chat_form: pre_chat)

        # 1. Visitor submits pre-chat form with message
        page.driver.post widget_create_customer_path(account_id: account.id, widget_id: widget.id), {
          name: 'Ellen Ripley',
          email: 'ripley@weyland.com',
          custom_fields: {
            'message' => 'Nostromo distress signal'
          }
        }

        expect(page.status_code).to eq(200)
        token_match = page.body.match(/data-widget-customer-session-token-value="([^"]+)"/)
        expect(token_match).to be_present
        session_token = token_match[1]

        # Verify chat back link is an <a> tag preserving token
        expect(page.body).to include('<a class="widget-chat-back"')
        expect(page.body).to include("customer_session_token=#{session_token}")

        # 2. Visitor clicks back to Home (simulated via Turbo GET with session token)
        visit widget_home_path(account_id: account.id, widget_id: widget.id, customer_session_token: session_token)
        expect(page.status_code).to eq(200)

        created_customer = account.customers.find_by(email: 'ripley@weyland.com')
        expect(created_customer).to be_present

        # Footer links must be <a> tags with token embedded
        expect(page.body).to include('<a class="widget-footer-nav-btn')
        token_nav_match = page.body.match(/customer_session_token=([A-Za-z0-9_\-.]+)/)
        expect(token_nav_match).to be_present
        expect(JwtService.decode(token_nav_match[1])['customer_id']).to eq(created_customer.id)

        # 3. Visitor navigates to Conversations tab via header token or query param
        page.driver.header 'X-Customer-Session-Token', session_token
        visit widget_conversations_path(account_id: account.id, widget_id: widget.id)
        expect(page.status_code).to eq(200)

        # Must display the visitor's conversation, not the empty state
        expect(page.body).to include('Nostromo distress signal')
        expect(page.body).not_to include('No conversations yet.')

        # Conversation item link must be an <a> tag preserving session
        expect(page.body).to include('<a class="widget-conv-item"')

        # 4. Visitor clicks "Start conversation" / messages with token
        visit widget_messages_path(account_id: account.id, widget_id: widget.id)
        expect(page.status_code).to eq(200)
        expect(page.body).not_to include('pre-chat-form')
        expect(page.body).to include('Nostromo distress signal')
      end
    end
  end
end
