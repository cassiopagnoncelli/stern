require_relative "lib/stern/version"

Gem::Specification.new do |spec|
  spec.name        = "stern"
  spec.version     = Stern::VERSION
  spec.authors     = ["Cassio Pagnoncelli"]
  spec.email       = ["cassiopagnoncelli@gmail.com"]
  spec.homepage    = "https://www.github.com/cassiopagnoncelli/stern"
  spec.summary     = "Double-entry ledger"
  spec.description = "Scalable double-entry ledger Rails engine to power financial backoffice."
  spec.license     = "Commercial, under written authorization"
  
  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the "allowed_push_host"
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  # spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://www.github.com/cassiopagnoncelli/stern.git"
  spec.metadata["changelog_uri"] = "https://www.github.com/cassiopagnoncelli/stern/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 7.0.4.3"
  spec.add_dependency "pg", ">= 1.4.5"

  # Development.
  spec.add_development_dependency "dotenv-rails"
  spec.add_development_dependency "awesome_print"
  spec.add_development_dependency "rspec-rails"
  spec.add_development_dependency "factory_bot_rails"
end
