require "bundler/setup"

APP_RAKEFILE = File.expand_path("spec/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

load "rails/tasks/statistics.rake"

require "bundler/gem_tasks"

namespace :assets do
  desc "Build Tailwind CSS into app/assets/builds/tailwind.css"
  task :build do
    sh "yarn install --frozen-lockfile"
    sh "yarn build:css"
  end
end

# Ensure the compiled CSS is fresh before the gem is packaged so host apps
# that mount the engine get a working stylesheet out of the box.
task build: "assets:build"
