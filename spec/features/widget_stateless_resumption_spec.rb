# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget Stateless Customer Resumption Flow', type: :feature do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, name: 'Support Widget')
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  let(:customer) do
    account.with_shard do
      create(:customer, account: account, name: 'Grace Hopper', email: 'grace@navy.mil')
    end
  end

  let!(:customer_inbox) do
    account.with_shard do
      create(:customer_inbox, customer: customer, inbox: inbox)
    end
  end

  let(:session_token) do
    account.with_shard do
      JwtService.encode({
        purpose: 'widget_customer_resume',
        account_id: account.id,
        widget_id: widget.id,
        inbox_id: inbox.id,
        customer_id: customer.id
      })
    end
  end

  describe 'Resuming conversation with session token' do
    it 'displays existing messages from customer and agent without showing pre-chat form' do
      account.with_shard do
        pre_chat = create(:channel_contact_form, account: account)
        widget.update!(pre_chat_form: pre_chat)

        conv = create(:conversation, account: account, inbox: inbox)
        conv.conversation_members.create!(conversation: conv, member: customer, account: account)
        create(:message, conversation: conv, account: account, inbox: inbox, sender: customer, content: 'First compiler bug discovered')
        agent = create(:user)
        create(:message, conversation: conv, account: account, inbox: inbox, sender: agent, content: 'We are deploying a moth repellent fix')

        page.driver.header 'Accept', 'text/vnd.turbo-stream.html'
        visit widget_messages_path(account_id: account.id, widget_id: widget.id, customer_session_token: session_token)

        expect(page.status_code).to eq(200)
        expect(page.body).not_to include('pre-chat-form')
        expect(page.body).to include('First compiler bug discovered')
        expect(page.body).to include('We are deploying a moth repellent fix')
      end
    end

    it 'appends new messages to the existing active conversation instead of creating a new one' do
      account.with_shard do
        conv = create(:conversation, account: account, inbox: inbox, status: :active)
        conv.conversation_members.create!(conversation: conv, member: customer, account: account)

        page.driver.header 'X-Customer-Session-Token', session_token
        page.driver.header 'Accept', 'text/vnd.turbo-stream.html'

        page.driver.post widget_create_message_path(account_id: account.id, widget_id: widget.id), {
          content: 'Follow-up message from returning user'
        }

        expect(page.status_code).to eq(200)
        expect(customer.conversations.count).to eq(1)
        expect(conv.messages.reload.last.content).to eq('Follow-up message from returning user')
      end
    end

    it 'restores existing customer identity by email query parameter without HMAC signature' do
      account.with_shard do
        page.driver.header 'Accept', 'text/html'
        visit widget_root_path(account_id: account.id, widget_id: widget.id, email: 'grace@navy.mil')

        expect(page.status_code).to eq(200)
        expect(page.body).to include('customerToken = "eyJ')
        token_match = page.body.match(/customerToken = "(eyJ[^"]+)"/)
        expect(token_match).to be_present
        payload = JwtService.decode(token_match[1])
        expect(payload['customer_id']).to eq(customer.id)
      end
    end

    it 'auto-resumes active conversation directly on root index when session token is provided' do
      account.with_shard do
        conv = create(:conversation, account: account, inbox: inbox, status: :active)
        conv.conversation_members.create!(conversation: conv, member: customer, account: account)
        create(:message, conversation: conv, account: account, inbox: inbox, sender: customer, content: 'Active compiler question')

        page.driver.header 'Accept', 'text/html'
        visit widget_root_path(account_id: account.id, widget_id: widget.id, customer_session_token: session_token)

        expect(page.status_code).to eq(200)
        expect(page.body).to include('Active compiler question')
        expect(page.body).not_to include('Start conversation')
      end
    end

    it 'routes back button to home by default, and to conversations when from: conversations' do
      account.with_shard do
        conv = create(:conversation, account: account, inbox: inbox, status: :active)
        conv.conversation_members.create!(conversation: conv, member: customer, account: account)

        # Default: back goes to home
        page.driver.header 'Accept', 'text/vnd.turbo-stream.html'
        visit widget_messages_path(account_id: account.id, widget_id: widget.id, customer_session_token: session_token)
        expect(page.body).to include(widget_home_path(locale: :en, account_id: account.id, widget_id: widget.id, format: :turbo_stream))

        # From conversations: back goes to conversations
        visit widget_messages_path(account_id: account.id, widget_id: widget.id, customer_session_token: session_token, from: 'conversations')
        expect(page.body).to include(widget_conversations_path(locale: :en, account_id: account.id, widget_id: widget.id, format: :turbo_stream))
      end
    end

    it 'renders customer conversations list when navigating with customer_session_token' do
      account.with_shard do
        conv = create(:conversation, account: account, inbox: inbox, status: :resolved, title: 'Resolved Billing Thread')
        conv.conversation_members.create!(conversation: conv, member: customer, account: account)

        page.driver.header 'Accept', 'text/vnd.turbo-stream.html'
        visit widget_conversations_path(account_id: account.id, widget_id: widget.id, customer_session_token: session_token)

        expect(page.status_code).to eq(200)
        expect(page.body).to include('Resolved Billing Thread')
        expect(page.body).not_to include('No conversations')
      end
    end
  end

  describe '100% Zero-Cookie Guarantee' do
    it 'never sets any session or cookie headers across all widget interactions' do
      account.with_shard do
        # 1. Widget Root (Home)
        page.driver.header 'Accept', 'text/html'
        visit widget_root_path(account_id: account.id, widget_id: widget.id)
        expect(page.status_code).to eq(200)
        set_cookie_header = page.response_headers['Set-Cookie']
        expect(set_cookie_header.to_s).not_to include('_widget_session')

        # 2. Messages Turbo Stream
        page.driver.header 'Accept', 'text/vnd.turbo-stream.html'
        visit widget_messages_path(account_id: account.id, widget_id: widget.id, customer_session_token: session_token)
        expect(page.status_code).to eq(200)
        expect(page.response_headers['Set-Cookie'].to_s).not_to include('_widget_session')

        # 3. Create Message
        page.driver.header 'X-Customer-Session-Token', session_token
        page.driver.post widget_create_message_path(account_id: account.id, widget_id: widget.id), { content: 'Stateless test' }
        expect(page.status_code).to eq(200)
        expect(page.response_headers['Set-Cookie'].to_s).not_to include('_widget_session')

        # 4. Identify Endpoint
        page.driver.post widget_identify_path(account_id: account.id, widget_id: widget.id), {
          identifier: 'user-cookie-test-999',
          name: 'Cookie Free'
        }
        expect(page.status_code).to eq(200)
        expect(page.response_headers['Set-Cookie'].to_s).not_to include('_widget_session')
      end
    end
  end
end
