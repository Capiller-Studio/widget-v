# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget::SecurityAndCors', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, allowed_hosts: ['https://example.com', 'https://client.com'])
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
  end
end
