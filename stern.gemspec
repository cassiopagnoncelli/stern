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

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the "allowed_push_host"
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  # spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"

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

  # Development.
  spec.add_development_dependency "rspec-rails"
  spec.add_development_dependency "factory_bot_rails"
  spec.add_development_dependency "shoulda-matchers", ">= 5.0"
end
