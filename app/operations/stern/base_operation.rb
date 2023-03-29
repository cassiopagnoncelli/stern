module Stern
  class BaseOperation
    include CreditsHelper

    self.abstract_class = true

    def call(direction: :do)
      case direction
      when :do, :redo, :forward, :forwards, :perform
        ApplicationRecord.transaction { lambda { perform }.call }
      when :undo, :backward, :backwards
        ApplicationRecord.transaction { lambda { undo }.call }
      else
        raise OperationDirectionNotProvidedError, "provide `direction` with :do or :undo"
      end
    end

    def perform
      raise OperationPerformNotImplementedError
    end

    def undo
      raise OperationUndoNotImplementedError
    end
  end
end
