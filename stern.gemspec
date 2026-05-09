require_relative "lib/stern/version"

Gem::Specification.new do |spec|
  spec.name        = "stern"
  spec.version     = Stern::VERSION
  spec.authors     = [ "Cassio Pagnoncelli" ]
  spec.email       = [ "cassiopagnoncelli@gmail.com" ]
  spec.homepage    = "https://www.github.com/cassiopagnoncelli/stern"
  spec.summary     = "Double-entry ledger"
  spec.description = "Scalable double-entry ledger Rails engine to power financial backoffice."
  # "Nonstandard" is the SPDX identifier for custom/commercial licenses. The actual
  # terms — commercial use requires written authorization from the author — are
  # documented in the README.
  spec.license     = "Nonstandard"

  spec.required_ruby_version = ">= 3.4"

  # Block accidental public publishing. `gem push` refuses to push anywhere
  # other than this host, and `.invalid` is a reserved TLD that never resolves
  # (RFC 2606), so any attempt fails fast. Stern is a private gem — distribute
  # via the GitHub repo as a Bundler `:git` source, not RubyGems.
  spec.metadata["allowed_push_host"] = "https://rubygems.invalid"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://www.github.com/cassiopagnoncelli/stern.git"
  spec.metadata["changelog_uri"] = "https://www.github.com/cassiopagnoncelli/stern/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "pg", ">= 1.4.5"
  spec.add_dependency "nokogiri", ">= 1.15.6"
  spec.add_dependency "xxhash", ">= 0.5"
  spec.add_dependency "prometheus-client", ">= 4.0"
  spec.add_dependency "propshaft", ">= 1.0"
  spec.add_dependency "cssbundling-rails", ">= 1.4"
  spec.add_dependency "idp-jwt"
  spec.add_dependency "omniauth_openid_connect", "~> 0.8"
  spec.add_dependency "omniauth-rails_csrf_protection"

  # Development.
  spec.add_development_dependency "rspec-rails"
  spec.add_development_dependency "factory_bot_rails"
  spec.add_development_dependency "shoulda-matchers", ">= 5.0"
end
