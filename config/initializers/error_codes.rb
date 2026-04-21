module Stern
  UnknownCurrencyError ||= Class.new(StandardError)
  UnrecognizedArgument ||= Class.new(StandardError)
  ArgumentMustBeInteger ||= Class.new(StandardError)
  ArgumentMustBeString ||= Class.new(StandardError)

  CannotProcessNonPickedSopError = Class.new(StandardError)
  CannotProcessAheadOfTimeError = Class.new(StandardError)

  BooksHashCollision ||= Class.new(StandardError)
  EntryPairHashCollision ||= Class.new(StandardError)
  MethodAlreadyDefined ||= Class.new(StandardError)
end
