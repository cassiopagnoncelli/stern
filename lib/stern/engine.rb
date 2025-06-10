module Stern
  class Engine < ::Rails::Engine
    isolate_namespace Stern

    # Use structure.sql instead of schema.rb to capture PostgreSQL sequences and functions
    config.active_record.schema_format = :sql

    config.generators do |generators|
      generators.test_framework :rspec
      generators.fixture_replacement :factory_bot
      generators.factory_bot dir: "spec/factories"
    end

    # Collapsing operations allows for operations to be defined in
    # subdirectories of app/operations/stern without the dir prefix,
    # that is, we can call PayPix directly instead of
    # PaymentProcessing::PayPix.
    #
    initializer "stern.configure_autoloader", before: :set_autoload_paths do
      require Engine.root.join("config/initializers/chart").to_s

      operations_module_name = STERN_DEFS[:operations]

      Dir[root.join("app/operations/stern/#{operations_module_name}/")].each do |dir|
        next if File.basename(dir) == "concerns"
        Rails.autoloaders.main.collapse(dir)
      end
    end
  end
end
