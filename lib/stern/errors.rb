module Stern
  class InvalidTime < StandardError; end
  class InvalidDate < StandardError; end
  class ShouldBeDateOrTimestamp < StandardError; end
  class TimestampShouldBeDateTime < StandardError; end
  class DateNotSpecified < StandardError; end
  class CreditTxIdSeqInvalid < StandardError; end

  class InvalidTxCode < StandardError; end
  class InvalidTxName < StandardError; end
  class InconsistentDefinitions < StandardError; end
  class InvalidBook < StandardError; end
  class BookDoesNotExist < StandardError; end
  class OperationDoesNotExist < StandardError; end
  class AmountShouldNotBeZero < StandardError; end
  class CascadeShouldBeBoolean < StandardError; end
  class AtomicShouldBeBoolean < StandardError; end
  class InvalidGroupingDatePrecision < StandardError; end
  class GidNotSpecified < StandardError; end
end
