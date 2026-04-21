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

    # The chart defines books, entry pairs, and the active operations module. It must be
    # loaded before autoload paths are set because:
    #   - Stern::Book and Stern::EntryPair reference it at class-definition time.
    #   - The active operations subdirectory is derived from it.
    initializer "stern.load_chart", before: :set_autoload_paths do
      require Engine.root.join("config/initializers/error_codes").to_s

      chart_name = ENV.fetch("STERN_CHART", "general")
      path = Engine.root.join("config/charts/#{chart_name}.yaml")
      unless path.exist?
        available = Dir[Engine.root.join("config/charts/*.yaml")].map { File.basename(_1, ".yaml") }
        raise "STERN_CHART=#{chart_name.inspect} not found; available: #{available}"
      end
      Stern.chart = Stern::Chart.load(path)
      Stern.currencies = Stern::Currencies.load(Engine.root.join("config/currencies_catalog.yaml"))

      # Collapsing operations allows for operations to be defined in subdirectories of
      # app/operations/stern without the dir prefix — e.g. `ChargePix` instead of
      # `General::ChargePix`.
      Dir[root.join("app/operations/stern/#{Stern.chart.operations_module}/")].each do |dir|
        next if File.basename(dir) == "concerns"
        Rails.autoloaders.main.collapse(dir)
      end
    end

    console do
      Object.include(Stern)
    end
  end
end
