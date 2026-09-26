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
  end
end
