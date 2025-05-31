module Stern
  class Engine < ::Rails::Engine
    isolate_namespace Stern

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
      Dir[root.join("app/operations/stern/payment_processing/")].each do |dir|
        next if File.basename(dir) == "concerns"
        Rails.autoloaders.main.collapse(dir)
      end
    end
  end
end
