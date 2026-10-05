# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Rack::Attack Rate Limiting in Widget', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) { create(:channel_web_widget, account: account, primary_inbox: inbox) }
  let(:form) { create(:channel_contact_form, account: account) }

  around do |example|
    original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    Rack::Attack.reset!
    example.run
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.reset!
    Rack::Attack.cache.store = original_store
  end

  describe 'POST contact form submissions' do
    it 'throttles contact form submissions after 5 attempts' do
      5.times do
        post contact_form_submit_path(account_id: account.id, form_id: form.id, locale: 'en'),
             params: { name: 'User', email: 'user@example.com', message: 'Hello' }
        expect(response.status).not_to eq(429)
      end

      post contact_form_submit_path(account_id: account.id, form_id: form.id, locale: 'en'),
           params: { name: 'User', email: 'user@example.com', message: 'Hello' }
      expect(response.status).to eq(429)
    end
  end

  describe 'POST pre-chat customer submissions' do
    it 'throttles pre-chat submissions after 5 attempts' do
      5.times do |i|
        post widget_create_customer_path(account_id: account.id, widget_id: widget.id),
             params: { name: "User #{i}", email: "user#{i}@example.com" }
        expect(response.status).not_to eq(429)
      end

      post widget_create_customer_path(account_id: account.id, widget_id: widget.id),
           params: { name: 'User 6', email: 'user6@example.com' }
      expect(response.status).to eq(429)
    end
  end
end
