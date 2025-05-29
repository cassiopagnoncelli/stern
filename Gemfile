source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }
ruby File.read(File.expand_path(File.join(__dir__, ".ruby-version"))).chomp

# Specify your gem's dependencies in stern.gemspec.
gemspec

group :development, :test do
  gem "pry"
  gem "awesome_print"
  gem "dotenv-rails"
  gem "shoulda-matchers", ">= 5.0"
  gem "rubocop"
  gem "rubocop-rails"
  gem "rubocop-rspec"
  gem "factory_bot_rails"
  gem "tracer"
end

