# frozen_string_literal: true

source "https://rubygems.org"

# Rails base
gem "rails", ">= 8.1.3"
gem "propshaft"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"
gem "bootsnap", require: false
gem "jbuilder"
gem "dotenv-rails"

# Asset & View layers (Unique to Widget)
gem "jsbundling-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "cssbundling-rails"
gem "slim-rails"
gem "actionpack-page_caching"
gem "invisible_captcha"

# CORS (widget is loaded cross-origin in customer iframes)
gem 'rack-cors'

group :development, :test do
  gem 'pry'
  gem 'pry-rails'
  gem 'awesome_print'
  gem 'factory_bot_rails'
  gem 'ffaker'
  gem 'rspec-rails'
  gem 'shoulda-matchers'
  gem 'database_cleaner-active_record'
  gem 'timecop'
  gem 'rubocop', require: false
  gem 'rubocop-rails', require: false
  gem 'rubocop-rspec', require: false
  gem 'rubocop-rails-omakase', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-thread_safety', require: false
  gem 'rubocop-capybara', require: false
  gem 'rubocop-minitest', require: false
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "brakeman", require: false
  gem 'slim_lint', '0.24.0', require: false
end

group :development do
  gem 'annotate'
  gem 'bullet'
  gem "web-console"
  gem "rack-mini-profiler"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
end

# ============================================================================
# Shared Backend (Core)
# ============================================================================
if ENV["CORE_PATH"] && !ENV["CORE_PATH"].empty?
  gem "core", path: ENV["CORE_PATH"]
elsif File.directory?(File.expand_path("../core", __dir__))
  gem "core", path: "../core"
elsif File.directory?(File.expand_path("./core", __dir__))
  gem "core", path: "./core"
else
  gem "core", git: "https://github.com/deskbolic/core.git", branch: "main"
end

# All shared functional gems are now provided by 'core'.
