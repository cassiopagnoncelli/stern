module Stern
  UnknownCurrencyError = Class.new(StandardError)
  UnrecognizedArgument = Class.new(StandardError)
  ArgumentMustBeString = Class.new(StandardError)

  CannotProcessNonPickedSopError = Class.new(StandardError)
  CannotProcessAheadOfTimeError = Class.new(StandardError)

  BooksHashCollision = Class.new(StandardError)
  EntryPairHashCollision = Class.new(StandardError)
  MethodAlreadyDefined = Class.new(StandardError)

  InsufficientFunds = Class.new(StandardError)
  # DB backstop: raised when `create_entry`/`destroy_entry` refuses a write
  # because `stern_books.non_negative = true` and the write would leave an
  # ending_balance < 0. Subclasses InsufficientFunds so existing rescues catch
  # both, while new code can distinguish the two layers.
  BalanceNonNegativeViolation = Class.new(InsufficientFunds)

  # Raised by `BaseOperation#call(idem_key:)` when an Operation with that key
  # already exists but its name/params do not match the call's. Carries enough
  # structured context for host apps to translate into a 409-style response or
  # log the diff without parsing the message.
  class IdempotencyConflict < StandardError
    attr_reader :idem_key, :existing_operation_id, :expected_params, :actual_params

    def initialize(idem_key:, existing:, attempted_name:, attempted_params:)
      @idem_key = idem_key
      @existing_operation_id = existing.id
      @expected_params = existing.params
      @actual_params = attempted_params
      same_name = existing.name == attempted_name
      detail = same_name ? "different parameters" : "different operation (#{existing.name} vs #{attempted_name})"
      super("Operation with idem_key #{idem_key} already exists with #{detail}")
    end
  end
end
