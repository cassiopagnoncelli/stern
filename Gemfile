source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }
ruby File.read(File.expand_path(File.join(__dir__, ".ruby-version"))).chomp

# Specify your gem's dependencies in stern.gemspec.
gemspec

# Local path override for idp-jwt during sibling-repo development.
gem "idp-jwt", path: "../idp-jwt"

group :development, :test do
  gem "pry"
  gem "awesome_print"
  gem "dotenv-rails"
  gem "shoulda-matchers", ">= 5.0"
  gem "rubocop-rails-omakase", require: false
  gem "factory_bot_rails"
  gem "tracer"
  gem "puma"
  gem "foreman"
end
