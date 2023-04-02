module Stern
  InvalidTimeError = Class.new(StandardError)
  ShouldBeDateOrTimestampError = Class.new(StandardError)
  TimestampShouldBeDateTimeError = Class.new(StandardError)
  CreditTxIdSeqInvalidError = Class.new(StandardError)

  InvalidTxNameError = Class.new(StandardError)
  InconsistentDefinitionsError = Class.new(StandardError)
  InvalidBookError = Class.new(StandardError)
  BookDoesNotExistError = Class.new(StandardError)
  OperationDoesNotExistError = Class.new(StandardError)
  AmountShouldNotBeZeroError = Class.new(StandardError)
  CascadeShouldBeBooleanError = Class.new(StandardError)
  AtomicShouldBeBooleanError = Class.new(StandardError)
  GidNotSpecifiedError = Class.new(StandardError)
  OperationNotConfirmedError = Class.new(StandardError)
  ArgumentError = Class.new(StandardError)
  OperationDirectionNotProvidedError = Class.new(StandardError)
end
