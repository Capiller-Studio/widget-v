# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget Messages Media Rendering', type: :feature do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, name: 'Support Widget')
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end
  let(:customer) { create(:customer, account: account) }
  let(:conversation) do
    account.with_shard do
      conv = create(:conversation, account: account, inbox: inbox)
      conv.conversation_members.create!(member: customer, account: account)
      conv
    end
  end
  let(:customer_session_token) do
    JwtService.encode({
      purpose: 'widget_customer_resume',
      account_id: account.id,
      widget_id: widget.id,
      inbox_id: inbox.id,
      customer_id: customer.id
    })
  end

  before do
    page.driver.header 'Accept', 'text/vnd.turbo-stream.html'
  end

  describe 'Rendering different media attachment types' do
    it 'renders a voice note as an audio player with inline SVG controls' do
      account.with_shard do
        create(:customer_inbox, customer: customer, inbox: inbox)
        msg = conversation.messages.create!(
          account: account,
          inbox: inbox,
          sender: customer,
          content: 'Here is my voice note',
          source: :web_widget
        )

        attachment = msg.attachments.create!(
          account: account,
          attachment_type: :audio
        )
        attachment.file.attach(
          io: StringIO.new('dummy wav audio data'),
          filename: 'voice-note-1700000000.wav',
          content_type: 'audio/wav'
        )

        visit widget_messages_path(
          account_id: account.id,
          widget_id: widget.id,
          conversation_id: conversation.id,
          customer_session_token: customer_session_token
        )

        expect(page.status_code).to eq(200)
        expect(page.body).to include('msg-attachment-audio')
        expect(page.body).to include('data-controller="audio-player"')
        expect(page.body).to include('audio-waveform')
        expect(page.body).to include('audio-icon-wrap')
      end
    end

    it 'renders a generic audio file attachment as a file link, not an audio player' do
      account.with_shard do
        create(:customer_inbox, customer: customer, inbox: inbox)
        msg = conversation.messages.create!(
          account: account,
          inbox: inbox,
          sender: customer,
          content: 'Here is the podcast audio file',
          source: :web_widget
        )

        attachment = msg.attachments.create!(
          account: account,
          attachment_type: :file
        )
        attachment.file.attach(
          io: StringIO.new('dummy mp3 file content'),
          filename: 'podcast-episode-1.mp3',
          content_type: 'audio/mpeg'
        )

        visit widget_messages_path(
          account_id: account.id,
          widget_id: widget.id,
          conversation_id: conversation.id,
          customer_session_token: customer_session_token
        )

        expect(page.status_code).to eq(200)
        expect(page.body).to include('msg-attachment-file')
        expect(page.body).to include('podcast-episode-1.mp3')
        expect(page.body).not_to include('data-controller="audio-player"')
      end
    end

    it 'renders an image attachment with img preview' do
      account.with_shard do
        create(:customer_inbox, customer: customer, inbox: inbox)
        msg = conversation.messages.create!(
          account: account,
          inbox: inbox,
          sender: customer,
          content: 'Check this screenshot',
          source: :web_widget
        )

        attachment = msg.attachments.create!(
          account: account,
          attachment_type: :image
        )
        attachment.file.attach(
          io: StringIO.new('dummy png data'),
          filename: 'screenshot.png',
          content_type: 'image/png'
        )

        visit widget_messages_path(
          account_id: account.id,
          widget_id: widget.id,
          conversation_id: conversation.id,
          customer_session_token: customer_session_token
        )

        expect(page.status_code).to eq(200)
        expect(page.body).to include('msg-attachment-img')
        expect(page.body).to include('attachment-image')
      end
    end

    it 'submits a new voice note through the widget message endpoint and renders it as audio player' do
      account.with_shard do
        create(:customer_inbox, customer: customer, inbox: inbox)
        voice_upload = Rack::Test::UploadedFile.new(
          StringIO.new('fake voice wav recording'),
          'audio/wav',
          original_filename: 'voice-note-99999.wav'
        )

        page.driver.post widget_create_message_path(
          account_id: account.id,
          widget_id: widget.id,
          conversation_id: conversation.id,
          customer_session_token: customer_session_token
        ), {
          content: 'Live voice recording',
          attachments: [voice_upload]
        }

        expect(page.status_code).to eq(200)
        expect(page.body).to include('msg-attachment-audio')
        expect(page.body).to include('data-controller="audio-player"')
      end
    end

    it 'submits an uploaded document and renders it as file attachment' do
      account.with_shard do
        create(:customer_inbox, customer: customer, inbox: inbox)
        file_upload = Rack::Test::UploadedFile.new(
          StringIO.new('fake pdf file content'),
          'application/pdf',
          original_filename: 'contract.pdf'
        )

        page.driver.post widget_create_message_path(
          account_id: account.id,
          widget_id: widget.id,
          conversation_id: conversation.id,
          customer_session_token: customer_session_token
        ), {
          content: 'Here is the signed contract',
          attachments: [file_upload]
        }

        expect(page.status_code).to eq(200)
        expect(page.body).to include('msg-attachment-file')
        expect(page.body).to include('contract.pdf')
        expect(page.body).not_to include('msg-attachment-audio')
      end
    end

    it 'submits multiple mixed attachments (audio + image + pdf) in a single message' do
      account.with_shard do
        create(:customer_inbox, customer: customer, inbox: inbox)
        audio_upload = Rack::Test::UploadedFile.new(StringIO.new('fake wav'), 'audio/wav', original_filename: 'voice.wav')
        image_upload = Rack::Test::UploadedFile.new(StringIO.new('fake png'), 'image/png', original_filename: 'photo.png')
        file_upload  = Rack::Test::UploadedFile.new(StringIO.new('fake pdf'), 'application/pdf', original_filename: 'guide.pdf')

        page.driver.post widget_create_message_path(
          account_id: account.id,
          widget_id: widget.id,
          conversation_id: conversation.id,
          customer_session_token: customer_session_token
        ), {
          content: 'All attachments combined',
          attachments: [audio_upload, image_upload, file_upload]
        }

        expect(page.status_code).to eq(200)
        expect(page.body).to include('msg-attachment-audio')
        expect(page.body).to include('msg-attachment-img')
        expect(page.body).to include('msg-attachment-file')
        expect(page.body).to include('guide.pdf')
      end
    end

    it 'submits an audio note with blank text content successfully' do
      account.with_shard do
        create(:customer_inbox, customer: customer, inbox: inbox)
        voice_upload = Rack::Test::UploadedFile.new(
          StringIO.new('fake voice content'),
          'audio/ogg',
          original_filename: 'voice-note.ogg'
        )

        page.driver.post widget_create_message_path(
          account_id: account.id,
          widget_id: widget.id,
          conversation_id: conversation.id,
          customer_session_token: customer_session_token
        ), {
          content: '',
          attachments: [voice_upload]
        }

        expect(page.status_code).to eq(200)
        expect(page.body).to include('msg-attachment-audio')
        expect(page.body).to include('data-controller="audio-player"')
      end
    end

    it 'handles uploads with application/octet-stream and uppercase extensions (.WAV and .PNG)' do
      account.with_shard do
        create(:customer_inbox, customer: customer, inbox: inbox)
        wav_upload = Rack::Test::UploadedFile.new(
          StringIO.new('fake wav data'),
          'application/octet-stream',
          original_filename: 'RECORDING.WAV'
        )
        png_upload = Rack::Test::UploadedFile.new(
          StringIO.new('fake png data'),
          'application/octet-stream',
          original_filename: 'DIAGRAM.PNG'
        )

        page.driver.post widget_create_message_path(
          account_id: account.id,
          widget_id: widget.id,
          conversation_id: conversation.id,
          customer_session_token: customer_session_token
        ), {
          content: 'Uppercase extension test',
          attachments: [wav_upload, png_upload]
        }

        expect(page.status_code).to eq(200)
        expect(page.body).to include('msg-attachment-audio')
        expect(page.body).to include('msg-attachment-img')
      end
    end
  end
end
