# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ContactForms', type: :request do
  let(:account) { create(:account) }
  let(:inbox) do
    account.with_shard do
      create(:inbox, account: account)
    end
  end
  let(:form) do
    account.with_shard do
      channel = create(
        :channel_contact_form,
        account: account,
        spam_protection_enabled: true,
        allow_attachments: true,
        send_confirmation_email: false
      )
      inbox.update!(channel: channel, primary_inbox: true)

      account.custom_fields.each_with_index do |cf, idx|
        create(:custom_field_resource, custom_field: cf, resource: channel, position: idx)
      end

      channel
    end
  end

  let(:uploaded_image) do
    Rack::Test::UploadedFile.new(
      StringIO.new('image-data'),
      'image/png',
      original_filename: 'screenshot.png'
    )
  end

  describe 'GET /:locale/f/:account_id/:form_id' do
    it 'renders the contact form page with custom fields' do
      account.with_shard do
        get contact_form_entry_path(account_id: account.id, form_id: form.id, locale: 'en')

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Subject')
        expect(response.body).to include('Email Address')
        expect(response.body).to include('Message')
      end
    end

    it 'prefills customer data when query params are provided' do
      account.with_shard do
        get contact_form_entry_path(
          account_id: account.id,
          form_id: form.id,
          locale: 'en',
          name: 'Jane Preloaded',
          email: 'jane.preloaded@example.com'
        )

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('jane.preloaded@example.com')
        expect(response.body).to include('Jane Preloaded')
      end
    end

    context 'when require_login is enabled on form' do
      before do
        account.with_shard do
          form.update!(require_login: true)
        end
      end

      it 'returns 401 unauthorized when HMAC credentials are missing' do
        get contact_form_entry_path(account_id: account.id, form_id: form.id, locale: 'en')

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to include('Missing HMAC credentials')
      end

      it 'returns 401 unauthorized when HMAC signature is invalid' do
        get contact_form_entry_path(
          account_id: account.id,
          form_id: form.id,
          locale: 'en',
          identifier: 'user_123',
          signature: 'invalid_sig'
        )

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to include('Invalid HMAC signature')
      end

      it 'renders successfully when HMAC signature is valid' do
        account.with_shard do
          identifier = 'user_123'
          valid_signature = OpenSSL::HMAC.hexdigest('sha256', form.secret, identifier)

          get contact_form_entry_path(
            account_id: account.id,
            form_id: form.id,
            locale: 'en',
            identifier: identifier,
            signature: valid_signature
          )

          expect(response).to have_http_status(:ok)
          expect(response.body).to include('Subject')
        end
      end
    end
  end

  describe 'POST /:locale/f/:account_id/:form_id' do
    let(:valid_params) do
      {
        name: 'Jane Doe',
        email: 'jane.doe@example.com',
        subject: 'Need help with billing',
        message: 'My payment failed on renewal.',
        priority: 'high'
      }
    end

    it 'creates a real Conversation, Customer, and Message in the shard database end-to-end without mocks' do
      expect {
        post contact_form_submit_path(account_id: account.id, form_id: form.id, locale: 'en'), params: valid_params

        expect(response).to redirect_to(
          contact_form_entry_path(
            account_id: account.id,
            form_id: form.id,
            locale: 'en',
            email: 'jane.doe@example.com',
            name: 'Jane Doe',
            success: 1
          )
        )
        expect(flash[:notice]).to be_present

        # Follow redirect to verify success screen renders even without cookies
        follow_redirect!
        expect(response.body).to include('contact-form-success')
        expect(response.body).to include('Thank you! Your message has been received.')
      }.to change { account.with_shard { account.conversations.count } }.by(1)
       .and change { account.with_shard { account.customers.count } }.by(1)

      account.with_shard do
        created_conversation = account.conversations.order(created_at: :desc).first
        expect(created_conversation.title).to eq('Need help with billing')
        expect(created_conversation.priority).to eq('high')
        expect(created_conversation.source).to eq('help_center')
        expect(created_conversation.inbox).to eq(inbox)

        created_customer = created_conversation.customers.first
        expect(created_customer.name).to eq('Jane Doe')
        expect(created_customer.email).to eq('jane.doe@example.com')

        created_message = created_conversation.messages.first
        expect(created_message.content).to eq('My payment failed on renewal.')
        expect(created_message.sender).to eq(created_customer)
        expect(created_message.source).to eq('help_center')
        expect(created_message.incoming?).to be(true)
      end
    end

    it 'attaches uploaded files end-to-end when allow_attachments is enabled' do
      post contact_form_submit_path(account_id: account.id, form_id: form.id, locale: 'en'),
           params: valid_params.merge(attachments: [uploaded_image])

      expect(response).to redirect_to(
        contact_form_entry_path(
          account_id: account.id,
          form_id: form.id,
          locale: 'en',
          email: 'jane.doe@example.com',
          name: 'Jane Doe',
          success: 1
        )
      )

      account.with_shard do
        created_conversation = account.conversations.order(created_at: :desc).first
        created_message = created_conversation.messages.first
        expect(created_message.attachments.count).to eq(1)
        expect(created_message.attachments.first.file).to be_attached
        expect(created_message.attachments.first.file.filename.to_s).to eq('screenshot.png')
      end
    end

    it 'silently rejects spam when honeypot field :nickname is filled' do
      expect {
        post contact_form_submit_path(account_id: account.id, form_id: form.id, locale: 'en'),
             params: valid_params.merge(nickname: 'spambot_user')

        expect(response).to redirect_to(
          contact_form_entry_path(
            account_id: account.id,
            form_id: form.id,
            locale: 'en',
            email: 'jane.doe@example.com',
            name: 'Jane Doe'
          )
        )
        expect(flash[:alert]).to be_present
      }.not_to change { account.with_shard { account.conversations.count } }
    end

    context 'when require_login is enabled on form' do
      before do
        account.with_shard do
          form.update!(require_login: true)
        end
      end

      it 'returns 401 unauthorized when HMAC credentials are missing on submission' do
        post contact_form_submit_path(account_id: account.id, form_id: form.id, locale: 'en'), params: valid_params

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to include('Missing HMAC credentials')
      end

      it 'submits successfully when valid HMAC credentials are provided' do
        account.with_shard do
          identifier = 'customer_999'
          valid_signature = OpenSSL::HMAC.hexdigest('sha256', form.secret, identifier)

          post contact_form_submit_path(
            account_id: account.id,
            form_id: form.id,
            locale: 'en'
          ), params: valid_params.merge(identifier: identifier, signature: valid_signature)

          expect(response).to redirect_to(
            contact_form_entry_path(
              account_id: account.id,
              form_id: form.id,
              locale: 'en',
              identifier: identifier,
              signature: valid_signature,
              email: 'jane.doe@example.com',
              name: 'Jane Doe',
              success: 1
            )
          )
          expect(flash[:notice]).to be_present
        end
      end
    end
  end
end
