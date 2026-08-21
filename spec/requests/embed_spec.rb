# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Embed', type: :request do
  let(:account) { create(:account) }
  let(:widget) { create(:channel_web_widget, account: account) }
  let(:form) { create(:channel_contact_form, account: account) }

  describe 'GET /w/:account_id/:widget_id/embed.js' do
    it 'returns the widget embed JavaScript with proper headers' do
      get embed_script_path(account_id: account.id, widget_id: widget.id)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include('application/javascript')
      expect(response.headers['Cache-Control']).to include('max-age=3600')
      expect(response.headers['Cache-Control']).to include('public')
      expect(response.headers['X-Content-Type-Options']).to eq('nosniff')
      expect(response.body).to include(widget.id.to_s)
    end
  end

  describe 'GET /f/:account_id/:form_id/embed.js' do
    it 'returns the contact form embed JavaScript with proper headers' do
      get embed_form_script_path(account_id: account.id, form_id: form.id)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include('application/javascript')
      expect(response.headers['Cache-Control']).to include('max-age=3600')
      expect(response.headers['Cache-Control']).to include('public')
      expect(response.headers['X-Content-Type-Options']).to eq('nosniff')
      expect(response.body).to include(form.id.to_s)
    end
  end
end
