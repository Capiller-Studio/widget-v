# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget::SecurityAndCors', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, allowed_hosts: [ 'https://example.com', 'https://client.com' ])
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'Frame Ancestors & Embedding Security' do
    it 'sets frame-ancestors CSP and removes X-Frame-Options' do
      account.with_shard do
        get widget_root_path(account_id: account.id, widget_id: widget.id)

        expect(response).to have_http_status(:ok)
        expect(response.headers['X-Frame-Options']).to be_nil
        expect(response.headers['Content-Security-Policy']).to include("frame-ancestors 'self' https://example.com https://client.com")
      end
    end

    it 'includes preview host when preview=true is passed' do
      account.with_shard do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('DESKBOLIC_URL').and_return('https://deskbolic.app')
        allow(ENV).to receive(:fetch).with('DESKBOLIC_URL', nil).and_return('https://deskbolic.app')

        get widget_root_path(account_id: account.id, widget_id: widget.id, preview: 'true')

        expect(response).to have_http_status(:ok)
        expect(response.headers['Content-Security-Policy']).to include('https://deskbolic.app')
      end
    end

    it 'returns 404 when widget does not exist' do
      get widget_root_path(account_id: account.id, widget_id: SecureRandom.uuid)

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include('Widget not found')
    end

    it 'returns 404 when widget belongs to a different account' do
      other_account = create(:account)
      get widget_root_path(account_id: other_account.id, widget_id: widget.id)

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include('Widget not found')
    end
  end

  describe 'Anonymous Chat Restrictions' do
    it 'rejects unauthenticated visitor when anonymous chat is disabled' do
      account.with_shard do
        widget.update!(flags: 0) # anonymous_allowed = false

        get widget_messages_path(account_id: account.id, widget_id: widget.id),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to include('Anonymous chat is disabled.')
      end
    end
  end

  describe 'HMAC Secure Identity Verification' do
    it 'returns 401 when secure identity is enforced and identifier is missing' do
      account.with_shard do
        widget.update!(secure_identity_enforced: true)

        get widget_messages_path(account_id: account.id, widget_id: widget.id)

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body['error']).to eq('HMAC Identity is required')
      end
    end

    it 'returns 401 when identifier is present but signature is invalid' do
      account.with_shard do
        widget.update!(secure_identity_enforced: true)

        get widget_messages_path(
          account_id: account.id,
          widget_id: widget.id,
          identifier: 'user_123',
          signature: 'invalid_signature_hex'
        )

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body['error']).to eq('Invalid signature')
      end
    end

    it 'authenticates visitor when valid HMAC signature is provided' do
      account.with_shard do
        widget.update!(secure_identity_enforced: true)
        identifier = 'user_valid_123'
        signature = OpenSSL::HMAC.hexdigest('sha256', widget.secret, identifier)

        get widget_messages_path(
          account_id: account.id,
          widget_id: widget.id,
          identifier: identifier,
          signature: signature,
          email: 'customer@example.com',
          name: 'Verified Customer'
        ), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(session[:customer_id]).to be_present
      end
    end
  end
end
