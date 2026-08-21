# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationHelper, type: :helper do
  let(:account) { create(:account) }
  let(:widget) { create(:channel_web_widget, account: account) }

  describe '#single_emoji_message?' do
    it 'returns true for a single standard emoji' do
      expect(helper.single_emoji_message?('👍')).to be true
      expect(helper.single_emoji_message?('❤️')).to be true
      expect(helper.single_emoji_message?('🔥')).to be true
      expect(helper.single_emoji_message?('🎉')).to be true
    end

    it 'returns true for single emojis with skin tone modifiers or zero-width joiners' do
      expect(helper.single_emoji_message?('👍🏽')).to be true
      expect(helper.single_emoji_message?('👨‍👩‍👧‍👦')).to be true
    end

    it 'returns true when emoji is wrapped in HTML tags with whitespace' do
      expect(helper.single_emoji_message?('<p>  🚀  </p>')).to be true
    end

    it 'returns false for multiple emojis or mixed text' do
      expect(helper.single_emoji_message?('👍👍')).to be false
      expect(helper.single_emoji_message?('Hello 👍')).to be false
      expect(helper.single_emoji_message?('Hello world')).to be false
      expect(helper.single_emoji_message?('')).to be false
      expect(helper.single_emoji_message?(nil)).to be false
    end
  end

  describe '#compact_stat_value' do
    it 'formats numbers below 1,000 as plain string' do
      expect(helper.compact_stat_value(0)).to eq('0')
      expect(helper.compact_stat_value(450)).to eq('450')
      expect(helper.compact_stat_value(999)).to eq('999')
    end

    it 'formats numbers in thousands with decimal when below 10K' do
      expect(helper.compact_stat_value(1_000)).to eq('1K')
      expect(helper.compact_stat_value(1_500)).to eq('1.5K')
      expect(helper.compact_stat_value(9_800)).to eq('9.8K')
    end

    it 'rounds numbers to nearest integer when 10K or higher' do
      expect(helper.compact_stat_value(10_000)).to eq('10K')
      expect(helper.compact_stat_value(15_400)).to eq('15K')
      expect(helper.compact_stat_value(100_000)).to eq('100K')
    end
  end

  describe '#category_article_count' do
    it 'returns published_articles_count of category' do
      category = double('Category', published_articles_count: 12)
      expect(helper.category_article_count(category)).to eq(12)
    end
  end

  describe '#article_read_minutes' do
    it 'returns estimated_read_time from article stats' do
      article = double('Article', stats: { 'estimated_read_time' => 5 })
      expect(helper.article_read_minutes(article)).to eq(5)
    end

    it 'defaults to 1 minute when stats are missing' do
      article = double('Article', stats: nil)
      expect(helper.article_read_minutes(article)).to eq(1)
    end
  end

  describe '#category_icon_fallback_tag' do
    it 'renders a span fallback tag' do
      tag = helper.category_icon_fallback_tag
      expect(tag).to include('class="widget-icon-chip-fallback"')
      expect(tag).to include('role="img"')
    end

    it 'accepts hidden attribute' do
      tag = helper.category_icon_fallback_tag(hidden: true)
      expect(tag).to include('hidden="hidden"')
    end
  end

  describe '#widget_route_params' do
    before do
      @account = account
      @widget = widget
      def helper.customer_session_token
        'sample_token'
      end
    end

    it 'generates a route params hash with account_id, widget_id, and locale' do
      params = helper.widget_route_params
      expect(params[:account_id]).to eq(account.id)
      expect(params[:widget_id]).to eq(widget.id)
      expect(params[:customer_session_token]).to eq('sample_token')
      expect(params[:locale]).to eq(I18n.locale)
    end

    it 'merges parameter overrides' do
      params = helper.widget_route_params(custom_param: 'value')
      expect(params[:custom_param]).to eq('value')
    end
  end

  describe '#widget_launcher_icon_tag' do
    it 'falls back to default header logo image tag when no custom icon is attached' do
      tag = helper.widget_launcher_icon_tag(widget)
      expect(tag).to include('header_logo')
    end
  end

  describe '#widget_conversation_icon_tag' do
    it 'falls back to default fav_icon image tag when no launcher icon is attached' do
      tag = helper.widget_conversation_icon_tag(widget)
      expect(tag).to include('fav_icon')
    end
  end
end
