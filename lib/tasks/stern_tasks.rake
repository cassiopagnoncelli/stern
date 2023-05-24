namespace :db do
  desc "Reset test and development databases"
  task :setup_env => :environment do
    Rake::Task['db:create'].invoke
    Rake::Task['db:migrate'].invoke
    Rake::Task['db:schema:load'].invoke
    Rake::Task['app:db:migrate:functions'].invoke(ENV['RAILS_ENV'])

    if Rails.env.development?
      Rake::Task['app:db:operations:refresh'].invoke
      Rake::Task['app:db:seed'].invoke
    end
  end

  namespace :migrate do
    desc "migrate db functions"
    task :functions, [:env] => :environment do |task, args|
      env = args.fetch(:env)
      unless %w[development test production qa].include?(env)
        raise ArgumentError, 'invalid environment'
      end

      file_path = Rails.root.join('..', '..', 'db', 'seeds', 'functions.sql').to_s
      exec_line = "RAILS_ENV=#{env} bundle exec rails db < #{file_path}"
      puts "#{exec_line}"
      system(exec_line)
    end
  end

  namespace :operations do
    desc "seed OperationDef model"
    task :refresh => :environment do
      printf "Persisting operation definitions... "
      Stern::OperationDef::Definitions.persist
      puts "OK"
    end
  end
end
