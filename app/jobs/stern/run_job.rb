module Stern
  class RunJob < ApplicationJob
    queue_as :default

    def perform(**args)
      ScheduledOperationService.list.each do |sop_id|
        ScheduledOperationService.process_sop(sop_id)
      end
    end
  end
end
