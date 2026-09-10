# frozen_string_literal: true

require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
ENV['MARKETING_URL'] ||= 'https://deskbolic.com'
ENV['DESKBOLIC_URL'] ||= 'https://deskbolic.app'
ENV['HELPBOLIC_URL'] ||= 'https://helpbolic.com'
require_relative '../config/environment'
abort('The Rails environment is running in production mode!') if Rails.env.production?
require 'rspec/rails'
require 'capybara/rspec'
require 'capybara/rails'
require 'shoulda/matchers'
require 'database_cleaner/active_record'
require 'factory_bot_rails'
require 'ffaker'
require 'timecop'

FactoryBot.definition_file_paths = [
  Core::Engine.root.join('spec/factories'),
  Rails.root.join('spec/factories')
]
FactoryBot.find_definitions if FactoryBot.factories.count == 0

ActiveRecord::Encryption.configure(
  primary_key: 'test_primary_key_for_rspec_testing',
  deterministic_key: 'test_deterministic_key_for_rspec',
  key_derivation_salt: 'test_key_derivation_salt_rspec'
)

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

Capybara.default_driver = :rack_test
Capybara.javascript_driver = :selenium_chrome_headless
Capybara.default_host = 'http://localhost:3000'
Capybara.app_host = 'http://localhost:3000'

RSpec.configure do |config|
  config.fixture_paths = [
    Rails.root.join('spec/fixtures')
  ]

  config.use_transactional_fixtures = false

  config.include FactoryBot::Syntax::Methods

  config.before(:suite) do
    DatabaseCleaner.clean_with(:truncation)
    Searchkick.disable_callbacks if defined?(Searchkick)
  end

  config.before do
    DatabaseCleaner.strategy = :transaction
  end

  config.before(:each, type: :feature) do
    DatabaseCleaner.strategy = :truncation
  end

  config.before do
    DatabaseCleaner.start
  end

  config.after do
    DatabaseCleaner.clean
  end

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
end
