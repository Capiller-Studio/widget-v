# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget::Home', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, name: 'HelpDesk Widget')
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'GET /w/:account_id/:widget_id (index)' do
    it 'renders the widget home successfully' do
      account.with_shard do
        get widget_root_path(account_id: account.id, widget_id: widget.id)

        expect(response).to have_http_status(:ok)
        expect(response.headers['Content-Security-Policy']).to include('frame-ancestors')
        expect(response.headers['X-Frame-Options']).to be_nil
        expect(response.body).to include('Start a conversation')
      end
    end

    it 'allows live preview from dashboard when preview param is true' do
      account.with_shard do
        get widget_root_path(account_id: account.id, widget_id: widget.id, preview: 'true')

        expect(response).to have_http_status(:ok)
        expect(response.headers['Content-Security-Policy']).to include(ENV['DESKBOLIC_URL'] || 'https://deskbolic.app')
      end
    end

    it 'returns 404 not found when widget does not exist' do
      get widget_root_path(account_id: account.id, widget_id: '00000000-0000-0000-0000-000000000000')

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include('Widget not found')
    end

    it 'returns 404 not found when account does not exist' do
      get widget_root_path(account_id: SecureRandom.uuid, widget_id: widget.id)

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 503 service unavailable when widget primary inbox is missing' do
      account.with_shard do
        widget_without_inbox = create(:channel_web_widget, account: account)

        get widget_root_path(account_id: account.id, widget_id: widget_without_inbox.id)

        expect(response).to have_http_status(:service_unavailable)
        expect(response.body).to include('Widget not configured')
      end
    end
  end

  describe 'GET /w/:account_id/:widget_id/home' do
    it 'returns a turbo stream updating the widget content with home partial' do
      account.with_shard do
        get widget_home_path(account_id: account.id, widget_id: widget.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('turbo-stream action="update" target="widget"')
      end
    end

    it 'embeds customer session token in footer navigation links when authenticated via header' do
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

        get widget_home_path(account_id: account.id, widget_id: widget.id),
            headers: {
              'Accept' => 'text/vnd.turbo-stream.html',
              'X-Customer-Session-Token' => token
            }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('<a class="widget-footer-nav-btn')
        token_match = response.body.match(/customer_session_token=([A-Za-z0-9_\-.]+)/)
        expect(token_match).to be_present
        expect(JwtService.decode(token_match[1])['customer_id']).to eq(customer.id)
      end
    end
  end

  describe 'GET /w/:account_id/:widget_id (index with session header)' do
    it 'auto-resumes active conversation directly when header token is provided' do
      account.with_shard do
        customer = create(:customer, account: account)
        create(:customer_inbox, customer: customer, inbox: inbox)
        conv = create(:conversation, account: account, inbox: inbox, status: :active)
        conv.conversation_members.create!(member: customer, account: account)
        create(:message, conversation: conv, account: account, inbox: inbox, sender: customer, content: 'Active thread message')

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        get widget_root_path(account_id: account.id, widget_id: widget.id),
            headers: { 'X-Customer-Session-Token' => token }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Active thread message')
      end
    end

    it 'marks unread agent messages as read and updates activity when auto-resuming conversation' do
      account.with_shard do
        customer = create(:customer, account: account)
        user = create(:user)
        create(:customer_inbox, customer: customer, inbox: inbox)
        conv = create(:conversation, account: account, inbox: inbox, status: :active)
        conv.conversation_members.create!(member: customer, account: account)
        agent_msg = create(:message, conversation: conv, account: account, inbox: inbox, sender: user, status: :sent, content: 'Agent unread response')

        allow(Utilities::ActivityHelpers).to receive(:update_activity)

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        get widget_root_path(account_id: account.id, widget_id: widget.id),
            headers: { 'X-Customer-Session-Token' => token }

        expect(response).to have_http_status(:ok)
        expect(agent_msg.reload.status).to eq('read')
        expect(Utilities::ActivityHelpers).to have_received(:update_activity).with(
          account.id,
          'Customer',
          customer.id
        ).at_least(:once)
      end
    end
  end
end
