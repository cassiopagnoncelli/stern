module Stern
  # Append-only audit log for every `BaseOperation#call` invocation, recording
  # both successful and failed attempts. Distinct from `Operation`, which only
  # commits on success and rolls back on `perform` failure — `OperationAttempt`
  # rows are written *outside* the operation's transaction so they survive a
  # rollback and give post-mortem visibility into what was tried.
  #
  # One row is written per call, after the work has resolved:
  #   - On success, `status` is `:success` and `operation_id` links to the
  #     committed `Operation` row.
  #   - On failure, `status` is `:failed` along with `error_class`,
  #     `error_message`, and a truncated `error_backtrace`. `operation_id`
  #     stays nil because the `Operation` insert was rolled back.
  #
  # `:pending` is a reserved sentinel — no normal write path emits it. It
  # exists so the column default (`0`) and the pruner have a recognizable
  # "writer never finalized this row" state to sweep, e.g. if a process
  # crashes between row build and update in some future code path.
  #
  # The `params` column holds the JSON-normalized projection of the op's live
  # inputs (same shape used for idempotency comparison), so failed attempts
  # are queryable by exact input shape.
  class OperationAttempt < ApplicationRecord
    BACKTRACE_LINES = 20

    belongs_to :operation, class_name: "Stern::Operation", optional: true

    enum :status, { pending: 0, success: 1, failed: 2 }

    validates :name, presence: true
    validates :status, presence: true
    validates :attempted_at, presence: true
  end
end
