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
        expect(session[:customer_id]).to be_present
        expect(session[:pre_chat_completed_widget_id]).to eq(widget.id)
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
          expect(session[:customer_id]).to be_present
        end
      end
    end

    context 'when secure identity is not enforced' do
      it 'identifies customer by identifier without signature' do
        account.with_shard do
          get widget_root_path(account_id: account.id, widget_id: widget.id, identifier: 'user_unsigned_123', name: 'Bob')

          expect(response).to have_http_status(:ok)
          expect(session[:customer_id]).to be_present
          customer = Customer.find(session[:customer_id])
          expect(customer.name).to eq('Bob')
        end
      end

      it 'restores existing customer by email without signature' do
        account.with_shard do
          existing = create(:customer, account: account, email: 'returning@example.com', name: 'Returning User')

          get widget_root_path(account_id: account.id, widget_id: widget.id, email: 'returning@example.com')

          expect(response).to have_http_status(:ok)
          expect(session[:customer_id]).to eq(existing.id)
        end
      end

      it 'does not create a new customer if email is not found' do
        account.with_shard do
          expect do
            get widget_root_path(account_id: account.id, widget_id: widget.id, email: 'unknown@example.com')
          end.not_to change(Customer, :count)

          expect(response).to have_http_status(:ok)
          expect(session[:customer_id]).to be_nil
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
          expect(session[:customer_id]).to eq(customer.id)
        end
      end
    end
  end
end
