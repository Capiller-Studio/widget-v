# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget::Locales', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account)
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'Scoped Locale Routing' do
    %w[en es de fr pt-BR ar ko].each do |loc|
      it "renders the widget for locale #{loc}" do
        account.with_shard do
          get widget_root_path(locale: loc, account_id: account.id, widget_id: widget.id)
          expect(response).to have_http_status(:ok)
        end
      end
    end
  end
end
