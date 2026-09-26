# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget Security & Anonymous Chat Flow', type: :feature do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, name: 'Secure Support Widget')
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'HMAC Secure Identity Verification' do
    before do
      account.with_shard do
        widget.update!(flags: 8) # secure_identity_enforced
      end
    end

    it 'rejects unauthenticated visitor with 401 when HMAC identifier is missing' do
      account.with_shard do
        visit widget_root_path(account_id: account.id, widget_id: widget.id)

        expect(page.status_code).to eq(401)
        expect(page.body).to include('HMAC Identity is required')
      end
    end

    it 'rejects visitor with 401 when HMAC signature is forged or invalid' do
      account.with_shard do
        visit widget_root_path(
          account_id: account.id,
          widget_id: widget.id,
          identifier: 'user_tampered',
          signature: 'invalid_hmac_hex_hash'
        )

        expect(page.status_code).to eq(401)
        expect(page.body).to include('Invalid signature')
      end
    end

    it 'authenticates visitor and provides signed customer token when valid HMAC signature is provided' do
      account.with_shard do
        identifier = 'verified_user_789'
        valid_signature = OpenSSL::HMAC.hexdigest('sha256', widget.secret, identifier)

        visit widget_root_path(
          account_id: account.id,
          widget_id: widget.id,
          identifier: identifier,
          signature: valid_signature,
          name: 'Ada Lovelace'
        )

        expect(page.status_code).to eq(200)
        expect(page.body).to include('customerToken = "eyJ')

        created_customer = account.customers.find_by(external_id: identifier)
        expect(created_customer).to be_present
        expect(created_customer.name).to eq('Ada Lovelace')
      end
    end
  end

  describe 'Anonymous Chat Policy' do
    it 'blocks anonymous visitors with 401 when anonymous chat is disabled' do
      account.with_shard do
        widget.update!(flags: 0) # anonymous chat disabled

        page.driver.header 'Accept', 'text/vnd.turbo-stream.html'
        visit widget_messages_path(account_id: account.id, widget_id: widget.id)

        expect(page.status_code).to eq(401)
        expect(page.body).to include('Anonymous chat is disabled')
      end
    end

    it 'automatically generates anonymous customer and token when anonymous chat is enabled' do
      account.with_shard do
        widget.update!(flags: 1) # anonymous_allowed

        page.driver.header 'Accept', 'text/vnd.turbo-stream.html'
        visit widget_messages_path(account_id: account.id, widget_id: widget.id)

        expect(page.status_code).to eq(200)
        expect(page.body).to include('turbo-stream action="update" target="widget"')
        expect(page.body).to include('data-widget-customer-session-token-value')

        anon_customer = account.customers.where("external_id LIKE ?", "anon-%").last
        expect(anon_customer).to be_present
      end
    end

    it 'identifies customer by external identifier without signature when HMAC is not enforced' do
      account.with_shard do
        widget.update!(flags: 0) # secure identity not enforced

        visit widget_root_path(
          account_id: account.id,
          widget_id: widget.id,
          identifier: 'crm_customer_555',
          name: 'Katherine Johnson'
        )

        expect(page.status_code).to eq(200)
        expect(page.body).to include('customerToken = "eyJ')

        customer = account.customers.find_by(external_id: 'crm_customer_555')
        expect(customer).to be_present
        expect(customer.name).to eq('Katherine Johnson')
      end
    end
  end
end
