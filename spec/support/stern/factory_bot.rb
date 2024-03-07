require "factory_bot_rails"

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods

  config.before(:suite) do
    FactoryBot.definition_file_paths << Pathname.new(Rails.root.join("../factories/stern"))
    FactoryBot.find_definitions
  end
end
