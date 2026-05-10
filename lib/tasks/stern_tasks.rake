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
        prune_interval:   ENV.fetch("STERN_PRUNE_INTERVAL",     "0").to_f,
        prune_success_days: ENV["STERN_PRUNE_SUCCESS_DAYS"]&.to_i,
        prune_failed_days:  ENV["STERN_PRUNE_FAILED_DAYS"]&.to_i,
        prune_pending_days: ENV["STERN_PRUNE_PENDING_DAYS"]&.to_i,
      ).start
    end
  end

  namespace :operation_attempts do
    desc "Prune Stern::OperationAttempt rows past their retention window. " \
         "Configurable via STERN_PRUNE_{SUCCESS,FAILED,PENDING}_DAYS, " \
         "STERN_PRUNE_BATCH_SIZE, STERN_PRUNE_SLEEP."
    task prune: :environment do
      Stern::OperationAttemptPruner.call(
        success_days: ENV.fetch("STERN_PRUNE_SUCCESS_DAYS", "14").to_i,
        failed_days:  ENV.fetch("STERN_PRUNE_FAILED_DAYS",  "90").to_i,
        pending_days: ENV.fetch("STERN_PRUNE_PENDING_DAYS",  "7").to_i,
        batch_size:   ENV.fetch("STERN_PRUNE_BATCH_SIZE", Stern::OperationAttemptPruner::DEFAULT_BATCH_SIZE.to_s).to_i,
        sleep_between: ENV.fetch("STERN_PRUNE_SLEEP", Stern::OperationAttemptPruner::DEFAULT_SLEEP_BETWEEN.to_s).to_f,
        triggered_by: "rake",
      )
    end
  end

  namespace :sop do
    # Both rescue tasks accept an optional second positional arg `force` that
    # extends the rescue to `:argument_error` SOPs. Only pass it after
    # deploying a fix to the underlying validation bug — otherwise the SOP
    # just lands back in `:argument_error` on the next pick. Anything other
    # than the literal string `force` is rejected so a typo can't silently
    # escalate to the riskier path.

    desc "Reset a single :runtime_error SOP back to :pending. " \
         "Usage: rake stern:sop:rescue[123] or rake stern:sop:rescue[123,force] " \
         "to also accept :argument_error SOPs."
    task :rescue, [ :id, :force ] => :environment do |_, args|
      raise ArgumentError, "unrecognized force flag #{args[:force].inspect}; pass `force` or omit" \
        unless args[:force].nil? || args[:force] == "force"
      force = args[:force] == "force"

      sop = Stern::ScheduledOperation.find(args.fetch(:id))
      sop.rescue!(force: force)
      Rails.logger.info("[stern:sop:rescue] rescued id=#{sop.id} name=#{sop.name} force=#{force}")
    end

    desc "Reset every :runtime_error SOP for a given op name. " \
         "Usage: rake stern:sop:rescue_all[ChargePix] or rake stern:sop:rescue_all[ChargePix,force] " \
         "to also rescue :argument_error SOPs of that name."
    task :rescue_all, [ :name, :force ] => :environment do |_, args|
      name = args.fetch(:name, nil)
      raise ArgumentError, "name required" if name.blank?
      raise ArgumentError, "unrecognized force flag #{args[:force].inspect}; pass `force` or omit" \
        unless args[:force].nil? || args[:force] == "force"
      force = args[:force] == "force"

      scope = force ?
        Stern::ScheduledOperation.where(status: [ :runtime_error, :argument_error ], name: name) :
        Stern::ScheduledOperation.runtime_error.where(name: name)

      count = 0
      scope.find_each do |sop|
        sop.rescue!(force: force)
        count += 1
      end
      Rails.logger.info("[stern:sop:rescue_all] rescued count=#{count} name=#{name} force=#{force}")
    end
  end
end
