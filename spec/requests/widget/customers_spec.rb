# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget::Customers', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, name: 'Support Widget')
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'POST /w/:account_id/:widget_id/contact (create_customer)' do
    it 'creates a customer from pre-chat form and transitions to messages view' do
      account.with_shard do
        post widget_create_customer_path(account_id: account.id, widget_id: widget.id),
             params: {
               name: 'Alex Rivera',
               email: 'alex@example.com'
             },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-widget-customer-session-token-value')
        customer = account.customers.find_by(email: 'alex@example.com')
        expect(customer&.name).to eq('Alex Rivera')
      end
    end

    it 'creates initial conversation and message when message content is provided' do
      account.with_shard do
        post widget_create_customer_path(account_id: account.id, widget_id: widget.id),
             params: {
               name: 'Alex Rivera',
               email: 'alex@example.com',
               custom_fields: {
                 'message' => 'I have a critical issue'
               }
             },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'HMAC Secure Identity Verification' do
    context 'when secure identity is enforced' do
      before do
        account.with_shard do
          widget.update!(flags: 8) # flag 4: secure_identity_enforced (bit 8)
        end
      end

      it 'returns 401 when identifier is missing' do
        get widget_root_path(account_id: account.id, widget_id: widget.id)

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body['error']).to eq('HMAC Identity is required')
      end

      it 'returns 401 when signature is invalid' do
        get widget_root_path(account_id: account.id, widget_id: widget.id, identifier: 'user_456', signature: 'bad_signature')

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body['error']).to eq('Invalid signature')
      end

      it 'authenticates successfully when signature is valid' do
        account.with_shard do
          identifier = 'user_456'
          valid_signature = OpenSSL::HMAC.hexdigest('sha256', widget.secret, identifier)

          get widget_root_path(account_id: account.id, widget_id: widget.id, identifier: identifier, signature: valid_signature, name: 'Alice')

          expect(response).to have_http_status(:ok)
          expect(response.body).to include('var customerToken = "eyJ')
          expect(account.customers.find_by(external_id: identifier)&.name).to eq('Alice')
        end
      end
    end

    context 'when secure identity is not enforced' do
      it 'identifies customer by identifier without signature' do
        account.with_shard do
          get widget_root_path(account_id: account.id, widget_id: widget.id, identifier: 'user_unsigned_123', name: 'Bob')

          expect(response).to have_http_status(:ok)
          customer = account.customers.find_by(external_id: 'user_unsigned_123')
          expect(customer&.name).to eq('Bob')
        end
      end

      it 'restores existing customer by email without signature' do
        account.with_shard do
          existing = create(:customer, account: account, email: 'returning@example.com', name: 'Returning User')

          get widget_root_path(account_id: account.id, widget_id: widget.id, email: 'returning@example.com')

          expect(response).to have_http_status(:ok)
          token_match = response.body.match(/customerToken = "(eyJ[^"]+)"/)
          expect(token_match).to be_present
          payload = JwtService.decode(token_match[1])
          expect(payload['customer_id']).to eq(existing.id)
        end
      end

      it 'does not create a new customer if email is not found' do
        account.with_shard do
          expect do
            get widget_root_path(account_id: account.id, widget_id: widget.id, email: 'unknown@example.com')
          end.not_to change(Customer, :count)

          expect(response).to have_http_status(:ok)
          expect(account.customers.where(email: 'unknown@example.com')).to be_empty
          expect(response.body).to include('customerToken = null')
        end
      end
    end

    context 'when customer is restored via X-Customer-Session-Token header' do
      it 'restores the customer without query parameters or cookies' do
        account.with_shard do
          customer = create(:customer, account: account, name: 'Token Restored')
          create(:customer_inbox, customer: customer, inbox: inbox)

          token = JwtService.encode({
            purpose: 'widget_customer_resume',
            account_id: account.id,
            widget_id: widget.id,
            inbox_id: inbox.id,
            customer_id: customer.id
          })

          get widget_root_path(account_id: account.id, widget_id: widget.id),
              headers: { 'X-Customer-Session-Token' => token }

          expect(response).to have_http_status(:ok)
          token_match = response.body.match(/customerToken = "(eyJ[^"]+)"/)
          expect(token_match).to be_present
          payload = JwtService.decode(token_match[1])
          expect(payload['customer_id']).to eq(customer.id)
        end
      end
    end
  end

  describe 'POST /w/:account_id/:widget_id/identify' do
    context 'when secure identity is disabled' do
      it 'identifies or creates a customer and returns JSON with customer_session_token' do
        account.with_shard do
          post widget_identify_path(account_id: account.id, widget_id: widget.id),
               params: {
                 identifier: 'ext-user-999',
                 name: 'External Visitor',
                 email: 'visitor@external.com'
               },
               as: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['success']).to be true
          expect(body['customer_session_token']).to be_present
          expect(body['customer']['email']).to eq('visitor@external.com')
        end
      end

      it 'updates widget with messages turbo stream and marks pre-chat complete' do
        account.with_shard do
          post widget_identify_path(account_id: account.id, widget_id: widget.id),
               params: {
                 identifier: 'ext-user-1000',
                 name: 'Turbo Visitor',
                 email: 'turbo@external.com'
               },
               headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

          expect(response).to have_http_status(:ok)
          expect(response.media_type).to eq('text/vnd.turbo-stream.html')
          expect(account.customers.find_by(email: 'turbo@external.com')).to be_present
        end
      end

      it 'restores an existing customer by email' do
        account.with_shard do
          existing = create(:customer, account: account, email: 'returning-sdk@example.com', name: 'Returning SDK')
          create(:customer_inbox, customer: existing, inbox: inbox)

          post widget_identify_path(account_id: account.id, widget_id: widget.id),
               params: { email: 'returning-sdk@example.com' },
               as: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['customer']['id']).to eq(existing.id)
        end
      end

      it 'stitches anonymous conversations and messages to the newly identified customer' do
        account.with_shard do
          anon = create(:customer, account: account, external_id: 'anon-abc-123', name: 'Anonymous')
          create(:customer_inbox, customer: anon, inbox: inbox)
          conv = create(:conversation, account: account, inbox: inbox)
          conv.conversation_members.create!(conversation: conv, member: anon, account: account)
          msg = create(:message, account: account, inbox: inbox, conversation: conv, sender: anon, content: 'Pre-login question')

          anon_token = JwtService.encode({
            purpose: 'widget_customer_resume',
            account_id: account.id,
            widget_id: widget.id,
            inbox_id: inbox.id,
            customer_id: anon.id
          })

          post widget_identify_path(account_id: account.id, widget_id: widget.id),
               params: {
                 identifier: 'user_real_456',
                 name: 'Real User',
                 email: 'real@example.com'
               },
               headers: { 'X-Customer-Session-Token' => anon_token },
               as: :json

          expect(response).to have_http_status(:ok)
          identified_customer = account.customers.find_by(external_id: 'user_real_456')
          expect(identified_customer).to be_present
          expect(conv.reload.customers).to include(identified_customer)
          expect(msg.reload.sender_id).to eq(identified_customer.id)
        end
      end

      it 'updates customer profile name and email if previously blank' do
        account.with_shard do
          cust = create(:customer, account: account, external_id: 'ext_blank_profile', name: nil, email: nil)
          create(:customer_inbox, customer: cust, inbox: inbox)

          post widget_identify_path(account_id: account.id, widget_id: widget.id),
               params: {
                 identifier: 'ext_blank_profile',
                 name: 'Now Filled Name',
                 email: 'filled@example.com'
               },
               as: :json

          expect(response).to have_http_status(:ok)
          expect(cust.reload.name).to eq('Now Filled Name')
          expect(cust.email).to eq('filled@example.com')
        end
      end
    end

    context 'when secure identity is enforced' do
      before do
        account.with_shard do
          widget.update!(flags: 8) # secure_identity_enforced
        end
      end

      it 'returns 401 when identifier is missing' do
        account.with_shard do
          post widget_identify_path(account_id: account.id, widget_id: widget.id),
               params: { email: 'unauthorized_without_id@example.com' },
               as: :json

          expect(response).to have_http_status(:unauthorized)
          body = JSON.parse(response.body)
          expect(body['error']).to eq('HMAC Identity is required')
        end
      end

      it 'returns 401 when signature is invalid' do
        account.with_shard do
          post widget_identify_path(account_id: account.id, widget_id: widget.id),
               params: {
                 identifier: 'cust_123',
                 signature: 'invalid_hmac_hash'
               },
               as: :json

          expect(response).to have_http_status(:unauthorized)
        end
      end

      it 'authenticates successfully when valid HMAC signature is provided' do
        account.with_shard do
          identifier = 'cust_valid_123'
          valid_signature = OpenSSL::HMAC.hexdigest('sha256', widget.hmac_token, identifier)

          post widget_identify_path(account_id: account.id, widget_id: widget.id),
               params: {
                 identifier: identifier,
                 signature: valid_signature,
                 name: 'Verified Customer',
                 email: 'verified@example.com'
               },
               as: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['success']).to be true
          expect(body['customer_session_token']).to be_present
        end
      end
    end
  end

  describe 'Stateless pre-chat custom conversation data preservation' do
    it 'preserves pre-chat custom conversation data into the first created message without cookies' do
      account.with_shard do
        title_field = create(:custom_field, account: account, key: 'topic', mapped_to: 'conversation.title')
        priority_field = create(:custom_field, account: account, key: 'urgency', mapped_to: 'conversation.priority')
        pre_chat = create(:channel_contact_form, account: account)
        create(:custom_field_resource, resource: pre_chat, custom_field: title_field, position: 1)
        create(:custom_field_resource, resource: pre_chat, custom_field: priority_field, position: 2)
        widget.update!(pre_chat_form: pre_chat)

        post widget_create_customer_path(account_id: account.id, widget_id: widget.id),
             params: {
               name: 'Stateless Tester',
               email: 'stateless@test.com',
               custom_fields: {
                 'topic' => 'Billing Question',
                 'urgency' => 'urgent'
               }
             },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        token_match = response.body.match(/data-widget-customer-session-token-value="([^"]+)"/)
        expect(token_match).to be_present
        token = token_match[1]

        # First message arrives carrying token and creates conversation with custom data
        post widget_create_message_path(account_id: account.id, widget_id: widget.id),
             params: { content: 'Need my invoice ASAP' },
             headers: {
               'Accept' => 'text/vnd.turbo-stream.html',
               'X-Customer-Session-Token' => token
             }

        expect(response).to have_http_status(:ok)
        conv = account.conversations.order(created_at: :desc).first
        expect(conv.title).to eq('Billing Question')
        expect(conv.priority).to eq('urgent')
        expect(conv.messages.first.content).to eq('Need my invoice ASAP')
      end
    end
  end
end
