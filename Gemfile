source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }
ruby File.read(File.expand_path(File.join(__dir__, ".ruby-version"))).chomp

# Specify your gem's dependencies in stern.gemspec.
gemspec

# idp-jwt is hosted on GitHub (not RubyGems). For sibling-repo development,
# override the git source without touching the lockfile:
#   bundle config local.idp-jwt ../idp-jwt
gem "idp-jwt", git: "https://github.com/cassiopagnoncelli/idp-jwt.git", branch: "main"

# Pinned to the default gem version shipped with Ruby 3.4.2 to avoid
# "ambiguous specs" warnings from coexisting installed versions.
gem "psych", "5.3.1"

group :development, :test do
  gem "pry"
  gem "dotenv-rails"
  gem "shoulda-matchers", "~> 7.0"
  gem "rubocop-rails-omakase", require: false
  gem "factory_bot_rails"
  gem "tracer"
  gem "puma"
  gem "foreman"
end

group :development do
  # awesome_print 1.9.2 references ActiveSupport::LogSubscriber.colorize_logging,
  # which Rails 8.1+ removed; keep it out of :test so the Rails-main matrix can
  # boot the dummy app for db:schema:load.
  gem "awesome_print"
end
