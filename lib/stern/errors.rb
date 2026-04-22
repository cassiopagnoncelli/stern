module Stern
  UnknownCurrencyError = Class.new(StandardError)
  UnrecognizedArgument = Class.new(StandardError)
  ArgumentMustBeInteger = Class.new(StandardError)
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
end
