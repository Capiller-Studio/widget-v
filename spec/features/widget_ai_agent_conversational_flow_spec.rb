# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget AI Agent Conversational Flow', type: :feature do
  let(:account) { create(:account) }
  let(:portal) { create(:help_center_portal, account: account) }
  let(:ai_agent) do
    account.with_shard do
      create(
        :ai_agent,
        account: account,
        portal: portal,
        name: 'Capiller Rely AI Assistant',
        confidence_threshold: 0.7
      )
    end
  end

  let(:inbox) do
    account.with_shard do
      create(:inbox, account: account, ai_agent: ai_agent)
    end
  end

  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, name: 'Support Widget')
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  let(:customer) do
    account.with_shard do
      create(:customer, account: account, name: 'Ahsan Khan', email: 'ahsan@example.com')
    end
  end

  let!(:customer_inbox) do
    account.with_shard do
      create(:customer_inbox, customer: customer, inbox: inbox)
    end
  end

  let(:session_token) do
    account.with_shard do
      JwtService.encode({
        purpose: 'widget_customer_resume',
        account_id: account.id,
        widget_id: widget.id,
        inbox_id: inbox.id,
        customer_id: customer.id
      })
    end
  end

  before do
    page.driver.header 'Accept', 'text/vnd.turbo-stream.html'
    page.driver.header 'X-Customer-Session-Token', session_token
  end

  describe 'Visitor chatting with AI Agent' do
    it 'debounces rapid multi-message bursts, broadcasts typing indicators, and renders AI reply with citations' do
      account.with_shard do
        # 1. Setup Help Center Article
        article = create(:help_center_article, account: account, portal: portal, title: 'Password Reset Guide', content: 'Go to login and click forgot password')
        article.translations.find_by(locale: 'en')&.update!(title: 'Password Reset Guide', content: 'Go to login and click forgot password', slug: 'password-reset-guide')

        # 2. Mock vector search and AI LLM reply
        search_double = double(
          'SearchkickResults',
          response: {
            'hits' => {
              'hits' => [ { '_id' => article.id.to_s, '_score' => 0.95 } ]
            }
          },
          empty?: false
        )
        allow(search_double).to receive(:select).and_yield(article).and_return([ article ])
        allow(HelpCenter::Article).to receive(:search).and_return(search_double)

        openai_client = instance_double(OpenAI::Client)
        allow(OpenAI::Client).to receive(:new).and_return(openai_client)
        allow(openai_client).to receive(:embeddings).and_return({
          'data' => [ { 'embedding' => [ 0.1, 0.2, 0.3 ] } ]
        })

        allow(Ai::Client).to receive(:call).and_return(
          'Hello Ahsan! To reset your password, visit the login page and click forgot password. [Read Guide](https://helpbolic.com/en/articles/password-reset-guide)'
        )

        # Expect ActionCable typing status broadcasts to customer token
        expect(ActionCable.server).to receive(:broadcast).with(
          customer_inbox.connection_token,
          hash_including(event: 'typing', status: 'start')
        ).at_least(:once)

        expect(ActionCable.server).to receive(:broadcast).with(
          customer_inbox.connection_token,
          hash_including(event: 'typing', status: 'stop')
        ).at_least(:once)

        # 3. Visitor sends rapid burst of messages
        page.driver.post widget_create_message_path(account_id: account.id, widget_id: widget.id), { content: 'Hi' }
        expect(page.status_code).to eq(200)

        page.driver.post widget_create_message_path(account_id: account.id, widget_id: widget.id), { content: 'My name is Ahsan' }
        expect(page.status_code).to eq(200)

        page.driver.post widget_create_message_path(account_id: account.id, widget_id: widget.id), { content: 'How do I reset my password?' }
        expect(page.status_code).to eq(200)

        conv = customer.conversations.first
        expect(conv).to be_present
        expect(conv.ai_active?).to be true

        # 4. Process the debounced worker
        Ai::AgentWorker.new.perform(account.id, conv.id, ai_agent.id)

        # 5. Verify conversation now has the AI reply
        ai_message = conv.messages.where(sender: ai_agent).last
        expect(ai_message).to be_present
        expect(ai_message.content).to include('Hello Ahsan!')
        expect(ai_message.content).to include('<a href="https://helpbolic.com/en/articles/password-reset-guide"')

        # 6. Visitor views messages in widget
        visit widget_messages_path(account_id: account.id, widget_id: widget.id, customer_session_token: session_token)
        expect(page.status_code).to eq(200)
        expect(page.body).to include('Hello Ahsan!')
        expect(page.body).to include('href="https://helpbolic.com/en/articles/password-reset-guide"')
      end
    end

    it 'escalates to human agent seamlessly when customer explicitly requests it in Spanish' do
      account.with_shard do
        # Visitor sends explicit escalation in Spanish
        page.driver.post widget_create_message_path(account_id: account.id, widget_id: widget.id), {
          content: 'Quiero hablar con un agente humano por favor'
        }
        expect(page.status_code).to eq(200)

        conv = customer.conversations.first
        expect(conv).to be_present
        conv.update!(locale: 'es')

        # Run AgentWorker
        Ai::AgentWorker.new.perform(account.id, conv.id, ai_agent.id)

        conv.reload
        expect(conv.ai_status).to eq('ai_handed_off')

        ai_message = conv.messages.where(sender: ai_agent).last
        expect(ai_message).to be_present
        expect(ai_message.content).to include(I18n.t('ai.agent.connecting_to_human', locale: :es))

        # Visitor loads messages
        visit widget_messages_path(account_id: account.id, widget_id: widget.id, customer_session_token: session_token)
        expect(page.body).to include(I18n.t('ai.agent.connecting_to_human', locale: :es))
      end
    end

    it 'stops AI agent immediately when a dashboard agent takes over and replies' do
      account.with_shard do
        # 1. Customer initiates conversation
        page.driver.post widget_create_message_path(account_id: account.id, widget_id: widget.id), {
          content: 'I need some help'
        }
        conv = customer.conversations.first
        expect(conv.ai_active?).to be true

        # 2. Human agent replies from dashboard
        agent_user = create(:user)
        create(:conversation_member, conversation: conv, member: agent_user, account: account)

        conv.messages.create!(
          account: account,
          inbox_id: inbox.id,
          sender: agent_user,
          content: 'Hello! I am a human agent taking over to help you.',
          visibility: :global
        )

        conv.reload
        expect(conv.ai_status).to eq('ai_handed_off')

        # 3. Customer sends another message; AI Agent worker is not scheduled because conversation was handed off
        expect(Ai::AgentWorker).not_to receive(:perform_in)

        page.driver.post widget_create_message_path(account_id: account.id, widget_id: widget.id), {
          content: 'Thanks, glad to talk to a human!'
        }

        expect(page.status_code).to eq(200)
        expect(conv.reload.ai_status).to eq('ai_handed_off')
      end
    end
  end
end
