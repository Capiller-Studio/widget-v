# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget::HelpCenter', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:domain) { create(:domain, :custom, :dns_verified, account: account, value: 'support.example.com', status: :active) }
  let(:portal) { create(:help_center_portal, account: account, domain: domain, status: :active) }
  let(:widget) do
    account.with_shard do
      w = create(:channel_web_widget, account: account, portal: portal, help_center_enabled: true)
      inbox.update!(channel: w, primary_inbox: true)
      w
    end
  end

  describe 'GET /w/:account_id/:widget_id/knowledge-base' do
    it 'renders the knowledge base categories list via Turbo Stream' do
      account.with_shard do
        category = create(:help_center_category, account: account, portal: portal, name: 'Getting Started', status: :active)

        get widget_help_center_path(account_id: account.id, widget_id: widget.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('turbo-stream action="update" target="widget"')
        expect(response.body).to include(category.name)
      end
    end

    it 'returns 404 not found when help center is disabled on widget' do
      account.with_shard do
        widget.update!(help_center_enabled: false)

        get widget_help_center_path(account_id: account.id, widget_id: widget.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'GET /w/:account_id/:widget_id/knowledge-base/categories/:category_id' do
    it 'renders the articles inside a category via Turbo Stream' do
      account.with_shard do
        category = create(:help_center_category, account: account, portal: portal, name: 'Billing', status: :active)
        article = create(:help_center_article, account: account, portal: portal, primary_category: category, title: 'Invoice FAQ', status: :published)
        category.articles << article

        get widget_help_category_path(account_id: account.id, widget_id: widget.id, category_id: category.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(article.title)
      end
    end
  end

  describe 'GET /w/:account_id/:widget_id/knowledge-base/categories/:category_id/articles/:article_id' do
    it 'renders article content via Turbo Stream' do
      account.with_shard do
        category = create(:help_center_category, account: account, portal: portal, name: 'General', status: :active)
        article = create(:help_center_article, account: account, portal: portal, primary_category: category, title: 'How to Reset Password', content: 'Follow these steps...', status: :published)
        category.articles << article

        get widget_help_article_path(account_id: account.id, widget_id: widget.id, category_id: category.id, article_id: article.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(article.title)
      end
    end

    it 'returns 404 when article is draft or does not exist' do
      account.with_shard do
        category = create(:help_center_category, account: account, portal: portal, status: :active)
        draft = create(:help_center_article, account: account, portal: portal, primary_category: category, status: :draft)

        get widget_help_article_path(account_id: account.id, widget_id: widget.id, category_id: category.id, article_id: draft.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'GET /w/:account_id/:widget_id/search' do
    it 'renders search results via Turbo Stream with empty query' do
      account.with_shard do
        get widget_search_path(account_id: account.id, widget_id: widget.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('turbo-stream action="update" target="help-results"')
      end
    end

    it 'renders search results via Turbo Stream when query is provided' do
      account.with_shard do
        allow(HelpCenter::Article).to receive(:search).and_return(
          double('SearchkickResults', total_count: 0, map: [], to_a: [], empty?: true, any?: false)
        )
        allow(HelpCenter::Category).to receive(:search).and_return(
          double('SearchkickResults', total_count: 0, map: [], to_a: [], empty?: true, any?: false)
        )

        get widget_search_path(account_id: account.id, widget_id: widget.id, query: 'test'), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('turbo-stream action="update" target="help-results"')
      end
    end
  end
end
