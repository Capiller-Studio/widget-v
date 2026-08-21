# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ContactForms', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:form) do
    account.with_shard do
      channel = create(:channel_contact_form, account: account, spam_protection_enabled: true, allow_attachments: true)
      inbox.update!(channel: channel, primary_inbox: true)
      custom_field = account.custom_fields.find_by(key: 'subject') || create(:custom_field, account: account, name: 'Subject', key: 'subject')
      create(:custom_field_resource, custom_field: custom_field, resource: channel)
      channel
    end
  end

  describe 'GET /f/:account_id/:form_id' do
    it 'renders the contact form page with custom fields' do
      account.with_shard do
        get contact_form_entry_path(account_id: account.id, form_id: form.id)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Subject')
      end
    end

    context 'when require_login is enabled on form' do
      before do
        account.with_shard do
          form.update!(require_login: true)
        end
      end

      it 'returns 401 unauthorized when HMAC credentials are missing' do
        get contact_form_entry_path(account_id: account.id, form_id: form.id)

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to include('Missing HMAC credentials')
      end

      it 'returns 401 unauthorized when HMAC signature is invalid' do
        get contact_form_entry_path(account_id: account.id, form_id: form.id, identifier: 'user_123', signature: 'invalid_sig')

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to include('Invalid HMAC signature')
      end

      it 'renders successfully when HMAC signature is valid' do
        account.with_shard do
          identifier = 'user_123'
          valid_signature = OpenSSL::HMAC.hexdigest('sha256', form.secret, identifier)

          get contact_form_entry_path(account_id: account.id, form_id: form.id, identifier: identifier, signature: valid_signature)

          expect(response).to have_http_status(:ok)
          expect(response.body).to include('Subject')
        end
      end
    end
  end

  describe 'POST /f/:account_id/:form_id' do
    it 'creates a conversation ticket successfully and redirects with notice' do
      mock_conv = double('Conversation', id: 1, identifier: 'TCK-1001')
      allow(Channels::ContactForms::ConversationCreator).to receive(:call).and_return(mock_conv)

      post contact_form_submit_path(account_id: account.id, form_id: form.id), params: {
        subject: 'Need help with billing',
        name: 'Jane Doe',
        email: 'jane@example.com'
      }

      expect(response).to redirect_to(contact_form_entry_path(account_id: account.id, form_id: form.id, locale: I18n.locale, email: 'jane@example.com', name: 'Jane Doe'))
      expect(flash[:notice]).to be_present
    end

    it 'silently rejects spam when honeypot field :nickname is filled' do
      expect(Channels::ContactForms::ConversationCreator).not_to receive(:call)

      post contact_form_submit_path(account_id: account.id, form_id: form.id), params: {
        nickname: 'spam_bot',
        subject: 'Spam ticket'
      }

      expect(response).to redirect_to(contact_form_entry_path(account_id: account.id, form_id: form.id, locale: I18n.locale))
      expect(flash[:alert]).to be_present
    end

    it 'handles errors gracefully and redirects with failure alert' do
      allow(Channels::ContactForms::ConversationCreator).to receive(:call).and_raise(StandardError.new('Creation failed'))

      post contact_form_submit_path(account_id: account.id, form_id: form.id), params: {
        subject: 'Broken'
      }

      expect(response).to redirect_to(contact_form_entry_path(account_id: account.id, form_id: form.id, locale: I18n.locale))
      expect(flash[:alert]).to be_present
    end
  end
end
