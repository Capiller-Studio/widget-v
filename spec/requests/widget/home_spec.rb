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
  end
end
