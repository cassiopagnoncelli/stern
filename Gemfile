source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }
ruby File.read(File.expand_path(File.join(__dir__, ".ruby-version"))).chomp

# Specify your gem's dependencies in stern.gemspec.
gemspec

# gem "pg"
# gem "rspec-rails"

group :development, :test do
  gem "byebug"
  gem "awesome_print"
  gem "dotenv-rails"
  gem "shoulda-matchers"
  gem "rubocop"
  gem "factory_bot_rails"
end

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"
