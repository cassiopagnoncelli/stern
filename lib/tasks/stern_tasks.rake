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

  namespace :sop do
    desc "Reset a single :runtime_error SOP back to :pending. Usage: rake stern:sop:rescue[123]"
    task :rescue, [ :id ] => :environment do |_, args|
      sop = Stern::ScheduledOperation.find(args.fetch(:id))
      sop.rescue!
      Rails.logger.info("[stern:sop:rescue] rescued id=#{sop.id} name=#{sop.name}")
    end

    desc "Reset every :runtime_error SOP for a given op name. Usage: rake stern:sop:rescue_all[ChargePix]"
    task :rescue_all, [ :name ] => :environment do |_, args|
      name = args.fetch(:name, nil)
      raise ArgumentError, "name required" if name.blank?

      count = 0
      Stern::ScheduledOperation.runtime_error.where(name: name).find_each do |sop|
        sop.rescue!
        count += 1
      end
      Rails.logger.info("[stern:sop:rescue_all] rescued count=#{count} name=#{name}")
    end
  end
end
