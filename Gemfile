source 'https://rubygems.org'

gemspec

gem 'sqlite3'

group :ci do
  gem 'mysql2'
  gem 'pg'
end

group :development do
  gem 'sucker_punch', require: %w(sucker_punch sucker_punch/async_syntax)
end

group :development, :test do
  gem 'faker'
  gem 'fakeweb'
  gem 'rubocop', '~> 0.41.2'
end

group :test do
  gem 'spy'
  gem 'mocha'
  gem 'simplecov', require: false
end

group :development, :test do
  gem 'byebug'
  gem 'pry'
end
