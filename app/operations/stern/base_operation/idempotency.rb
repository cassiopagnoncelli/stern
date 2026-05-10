module Stern
  class BaseOperation
    # Resolves an `idem_key` against the `stern_operations.idem_key` partial
    # unique index.
    #
    # Contract:
    #   * `find_existing_operation(nil)` returns nil (no idempotency in play).
    #   * With a non-nil key, returns the matching `Operation` row when
    #     `name` and JSON-normalized `params` agree, returns nil when no
    #     row exists, and raises `Stern::IdempotencyConflict` when a row
    #     exists with mismatched name or params (a replay attempt with
    #     changed inputs is a programmer error, not a benign duplicate).
    #   * Comparison goes through `json_normalized_params` so live Ruby
    #     values (Symbols, Times, BigDecimals, …) compare equal to the
    #     JSON-roundtripped shape `Operation.params` returns from its
    #     `json` column. Without this, replaying an op with non-scalar
    #     inputs would falsely diverge from its stored row.
    #
    # The race-loser path in `BaseOperation#call` calls back into this
    # method after a `RecordNotUnique` rollback to confirm the winner's
    # name/params match (same comparison, same raise), so the pre-flight
    # check and the post-rollback check stay in lockstep.
    module Idempotency
      private

      # Looks up an Operation by idem_key. Returns the matching Operation if params also
      # match, nil if no Operation with that key exists, and raises if one exists with
      # different params (attempted replay with changed inputs).
      #
      # Comparison goes through `json_normalized_params` so live Ruby values (Symbols,
      # Times, BigDecimals, …) compare equal to the JSON-roundtripped shape that
      # `Operation.params` returns from its `json` column. Without this, replaying an
      # op whose inputs include any non-Integer/String/Bool would falsely diverge from
      # its stored row.
      def find_existing_operation(idem_key)
        return nil if idem_key.nil?

        op = Operation.find_by(idem_key:)
        return nil if op.nil?
        return op if op.name == operation_name && op.params == json_normalized_params

        raise ::Stern::IdempotencyConflict.new(
          idem_key: idem_key,
          existing: op,
          attempted_name: operation_name,
          attempted_params: operation_params,
        )
      end
    end
  end
end
