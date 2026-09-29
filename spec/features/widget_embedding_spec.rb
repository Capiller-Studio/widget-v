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
    it 'renders the widget home page with conversation starter and branding' do
      account.with_shard do
        visit widget_root_path(account_id: account.id, widget_id: widget.id)

        expect(page.status_code).to eq(200)
        expect(page).to have_content('Hi there')
        expect(page).to have_content('Start a conversation')
        expect(page).to have_content('Powered by Deskbolic')
      end
    end

    it 'embeds the bi-directional postMessage token negotiation script in layout' do
      account.with_shard do
        visit widget_root_path(account_id: account.id, widget_id: widget.id)

        expect(page.body).to include('deskbolic:request_token')
        expect(page.body).to include('deskbolic:token_response')
        expect(page.body).to include('deskbolic:token-updated')
        expect(page.body).to include('turbo:before-fetch-request')
        expect(page.body).to include('X-Customer-Session-Token')
        expect(page.body).to include('window.localStorage.removeItem(storageKey)')
        expect(page.body).to include('deskbolic:set-customer')
        expect(page.body).to include('deskbolic:reset')
        expect(page.body).to include(widget_identify_path(account_id: account.id, widget_id: widget.id, customer_session_token: nil))
      end
    end

    it 'renders pre-chat form when pre-chat is required and visitor is unknown' do
      account.with_shard do
        pre_chat = create(:channel_contact_form, account: account)
        widget.update!(pre_chat_form: pre_chat)
        page.driver.header 'Accept', 'text/vnd.turbo-stream.html'

        visit widget_messages_path(account_id: account.id, widget_id: widget.id)

        expect(page.status_code).to eq(200)
        expect(page.body).to include('turbo-stream action="update" target="widget"')
        expect(page.body).to include('pre_chat')
      end
    end

    it 'bypasses pre-chat form and loads messages when customer_session_token is provided' do
      account.with_shard do
        pre_chat = create(:channel_contact_form, account: account)
        widget.update!(pre_chat_form: pre_chat)
        customer = create(:customer, account: account, name: 'Verified Visitor')
        create(:customer_inbox, customer: customer, inbox: inbox)

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        page.driver.header 'Accept', 'text/vnd.turbo-stream.html'
        visit widget_messages_path(account_id: account.id, widget_id: widget.id, customer_session_token: token)

        expect(page.status_code).to eq(200)
        expect(page.body).to include('messages-list')
        expect(page.body).not_to include('pre_chat')
      end
    end
  end

  describe 'Embed script endpoint' do
    it 'serves embed.js with SDK methods and audio chime synthesizer' do
      account.with_shard do
        visit embed_script_path(account_id: account.id, widget_id: widget.id)

        expect(page.status_code).to eq(200)
        expect(page.body).to include('window.DeskbolicWidget')
        expect(page.body).to include('window.Deskbolic')
        expect(page.body).to include('setCustomer')
        expect(page.body).to include('setUser')
        expect(page.body).to include('resetCustomer')
        expect(page.body).to include('reset:')
        expect(page.body).to include('setLocale')
        expect(page.body).to include('playNotificationSound')
        expect(page.body).to include('playSentSound')
        expect(page.body).to include('mute:')
        expect(page.body).to include('unmute:')
        expect(page.body).to include('isMuted:')
        expect(page.body).to include('data-base-domain')
        expect(page.body).to include('deskbolic:request_token')
        expect(page.body).to include('deskbolic:sound:sent')
        expect(page.body).to include('deskbolic:ready')
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
