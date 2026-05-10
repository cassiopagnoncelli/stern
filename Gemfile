source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }
ruby File.read(File.expand_path(File.join(__dir__, ".ruby-version"))).chomp

# Specify your gem's dependencies in stern.gemspec.
gemspec

# idp-jwt is hosted on GitHub (not RubyGems). For sibling-repo development,
# override the git source without touching the lockfile:
#   bundle config local.idp-jwt ../idp-jwt
gem "idp-jwt", git: "https://github.com/cassiopagnoncelli/idp-jwt.git", branch: "main"

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
