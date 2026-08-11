# frozen_string_literal: true

module ApplicationHelper
  def widget_route_params(overrides = {})
    {
      account_id: @account&.id || params[:account_id],
      widget_id: @widget&.id || params[:widget_id],
      customer_session_token: customer_session_token,
      locale: I18n.locale
    }.compact.merge(overrides)
  end

  def single_emoji_message?(content)
    text = strip_tags(content).to_s.strip
    return false if text.blank?

    clusters = text.scan(/\X/)
    return false unless clusters.one?

    single_emoji_pattern = /
      \A
      (?:
        (?:[\u{1F1E6}-\u{1F1FF}]{2}) |
        (?:[0-9#*]\uFE0F?\u20E3) |
        (?:
          (?:\p{Emoji_Presentation}|\p{Extended_Pictographic}\uFE0F?)
          \p{Emoji_Modifier}?
          (?:
            \u200D
            (?:\p{Emoji_Presentation}|\p{Extended_Pictographic}\uFE0F?)
            \p{Emoji_Modifier}?
          )*
        )
      )
      \z
    /x

    text.match?(single_emoji_pattern)
  end

  def category_icon_svg(category)
    if category&.image&.attached?
      safe_join([
        image_tag(
          category_image_path(category.image),
          class: "widget-icon-chip-img",
          alt: category.name.to_s.presence || "Category icon",
          onerror: "this.onerror=null;this.hidden=true;this.nextElementSibling.hidden=false;"
        ),
        category_icon_fallback_tag(hidden: true)
      ])
    else
      category_icon_fallback_tag
    end
  end

  def category_icon_fallback_tag(hidden: false)
    tag.span(
      "",
      class: "widget-icon-chip-fallback",
      role: "img",
      aria: { label: "Category icon" },
      hidden: hidden
    )
  end

  def category_image_path(image)
    filename = ERB::Util.url_encode(image.filename.to_s)
    prefix = Rails.application.config.active_storage.routes_prefix || "/rails/active_storage"

    "#{prefix}/blobs/redirect/#{image.blob.signed_id}/#{filename}?disposition=inline"
  end

  def widget_launcher_icon_tag(widget, **options)
    options[:alt] ||= "Widget Icon"
    if widget&.account&.feature_enabled?(:custom_branding) && widget&.custom_branding? && widget&.launcher_icon&.attached?
      image_tag(widget.scaled_launcher_icon, **options)
    else
      image_tag("header_logo.png", **options)
    end
  end

  def widget_conversation_icon_tag(widget, **options)
    options[:alt] ||= "Widget Icon"
    if widget&.launcher_icon&.attached?
      image_tag(widget.scaled_launcher_icon, **options)
    else
      image_tag("fav_icon.png", **options)
    end
  end

  def compact_stat_value(value)
    number = value.to_i
    return number.to_s if number < 1_000

    compact = number / 1_000.0
    formatted = compact >= 10 ? compact.round.to_s : format("%.1f", compact).sub(/\.0\z/, "")
    "#{formatted}K"
  end

  def category_article_count(category)
    if defined?(@category_article_counts) && @category_article_counts
      return @category_article_counts[category.id] || 0
    end

    category.articles.size
  end

  def article_read_minutes(article)
    word_count = strip_tags(article.content.to_s).scan(/\w+/).size
    return 0 if word_count.zero?

    (word_count / 200.0).ceil
  end
end
