# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget::Attachments', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, flags: 1)
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'POST /w/:account_id/:widget_id/messages with attachment' do
    it 'creates a message with attached files' do
      account.with_shard do
        customer = create(:customer, account: account)
        create(:customer_inbox, customer: customer, inbox: inbox)

        token = JwtService.encode({
          purpose: 'widget_customer_resume',
          account_id: account.id,
          widget_id: widget.id,
          inbox_id: inbox.id,
          customer_id: customer.id
        })

        file = fixture_file_upload(Rails.root.join('../core/spec/fixtures/files/test.png'), 'image/png') rescue nil
        file ||= Rack::Test::UploadedFile.new(StringIO.new('fake-image-data'), 'image/png', original_filename: 'test.png')

        expect do
          post widget_create_message_path(account_id: account.id, widget_id: widget.id, customer_session_token: token),
               params: {
                 content: 'Check this screenshot',
                 attachments: [ file ]
               },
               headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
        end.to change(Message, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Check this screenshot')
        expect(response.body).to include('attachment-image')
      end
    end
  end
end
