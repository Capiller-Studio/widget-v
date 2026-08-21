# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget::Conversations', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account)
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'GET /w/:account_id/:widget_id/conversations' do
    it 'renders the conversations list for authenticated customer via Turbo Stream' do
      account.with_shard do
        customer = create(:customer, account: account)
        create(:customer_inbox, customer: customer, inbox: inbox)
        conversation = create(:conversation, account: account, inbox: inbox)
        conversation.conversation_members.create!(member: customer, account: account)
        create(:message, account: account, inbox: inbox, conversation: conversation, sender: customer, content: 'Recent question')

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        get widget_conversations_path(account_id: account.id, widget_id: widget.id, customer_session_token: token),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('turbo-stream action="update" target="widget"')
        expect(response.body).to include('Recent question')
      end
    end

    it 'renders empty conversations list when visitor has no previous conversations' do
      account.with_shard do
        get widget_conversations_path(account_id: account.id, widget_id: widget.id),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('turbo-stream action="update" target="widget"')
      end
    end
  end
end
