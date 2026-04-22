# frozen_string_literal: true

namespace :stern do
  namespace :worker do
    desc "Run the Stern scheduled-operation worker loop. Configurable via " \
         "STERN_WORKER_CONCURRENCY, STERN_POLL_INTERVAL, STERN_JANITOR_INTERVAL."
    task start: :environment do
      require "stern/workers/runner"
      Stern::Workers::Runner.new(
        concurrency:      ENV.fetch("STERN_WORKER_CONCURRENCY", Stern::Workers::Runner::DEFAULT_CONCURRENCY.to_s).to_i,
        poll_interval:    ENV.fetch("STERN_POLL_INTERVAL",      Stern::Workers::Runner::DEFAULT_POLL_INTERVAL.to_s).to_f,
        janitor_interval: ENV.fetch("STERN_JANITOR_INTERVAL",   Stern::Workers::Runner::DEFAULT_JANITOR_INTERVAL.to_s).to_f,
      ).start
    end
  end
end
