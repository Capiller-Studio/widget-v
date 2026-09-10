# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget Embedding & Frame Feature', type: :feature do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, name: 'Live Support Chat')
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'Widget iframe interface' do
    it 'renders the widget home page with conversation starter' do
      account.with_shard do
        visit widget_root_path(account_id: account.id, widget_id: widget.id)

        expect(page.status_code).to eq(200)
        expect(page).to have_content('Hi there')
        expect(page).to have_content('Start a conversation')
        expect(page).to have_content('Powered by Deskbolic')
      end
    end
  end

  describe 'Demo embedding page' do
    it 'loads the client website demo with widget configuration' do
      account.with_shard do
        visit demo_path(account_id: account.id, widget_id: widget.id)

        expect(page.status_code).to eq(200)
        expect(page).to have_css("script[src*='embed.js']", visible: false)
      end
    end
  end
end
