# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget::Customers', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, name: 'Support Widget')
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'POST /w/:account_id/:widget_id/contact (create_customer)' do
    it 'creates a customer from pre-chat form and transitions to messages view' do
      account.with_shard do
        post widget_create_customer_path(account_id: account.id, widget_id: widget.id),
             params: {
               name: 'Alex Rivera',
               email: 'alex@example.com'
             },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(session[:customer_id]).to be_present
        expect(session[:pre_chat_completed_widget_id]).to eq(widget.id)
      end
    end

    it 'creates initial conversation and message when message content is provided' do
      account.with_shard do
        post widget_create_customer_path(account_id: account.id, widget_id: widget.id),
             params: {
               name: 'Alex Rivera',
               email: 'alex@example.com',
               custom_fields: {
                 'message' => 'I have a critical issue'
               }
             },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'HMAC Secure Identity Verification' do
    context 'when secure identity is enforced' do
      before do
        account.with_shard do
          widget.update!(flags: 8) # flag 4: secure_identity_enforced (bit 8)
        end
      end

      it 'returns 401 when identifier is missing' do
        get widget_root_path(account_id: account.id, widget_id: widget.id)

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body['error']).to eq('HMAC Identity is required')
      end

      it 'returns 401 when signature is invalid' do
        get widget_root_path(account_id: account.id, widget_id: widget.id, identifier: 'user_456', signature: 'bad_signature')

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body['error']).to eq('Invalid signature')
      end

      it 'authenticates successfully when signature is valid' do
        account.with_shard do
          identifier = 'user_456'
          valid_signature = OpenSSL::HMAC.hexdigest('sha256', widget.secret, identifier)

          get widget_root_path(account_id: account.id, widget_id: widget.id, identifier: identifier, signature: valid_signature, name: 'Alice')

          expect(response).to have_http_status(:ok)
          expect(session[:customer_id]).to be_present
        end
      end
    end
  end
end
