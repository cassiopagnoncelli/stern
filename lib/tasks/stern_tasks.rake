require_relative '../../db/seeds/operation_defs'

namespace :db do
  namespace :migrate do
    desc "migrate db functions"
    task :functions do
      file_path = Rails.root.join('..', '..', 'db', 'seeds', 'functions.sql').to_s
      system("rails db < #{file_path}")
    end
  end

  namespace :seed do
    desc "seed OperationDef model"
    task :operation_defs do
      seed_operation_defs
    end
  end
end
