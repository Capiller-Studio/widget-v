# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Demo', type: :request do
  let(:account) { create(:account) }
  let(:widget) { create(:channel_web_widget, account: account) }
  let(:form) { create(:channel_contact_form, account: account) }

  describe 'GET /demo/widget/:account_id/:widget_id' do
    it 'renders the demo page for the widget successfully' do
      get demo_path(account_id: account.id, widget_id: widget.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(widget.id.to_s)
    end

    it 'returns 404 when widget is not found' do
      get demo_path(account_id: account.id, widget_id: '00000000-0000-0000-0000-000000000000')

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /demo/form/:account_id/:form_id' do
    it 'renders the demo page for the contact form successfully' do
      get demo_form_path(account_id: account.id, form_id: form.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(form.id.to_s)
    end

    it 'returns 404 when form is not found' do
      get demo_form_path(account_id: account.id, form_id: '00000000-0000-0000-0000-000000000000')

      expect(response).to have_http_status(:not_found)
    end
  end
end
