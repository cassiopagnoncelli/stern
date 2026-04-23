-- Fires a Postgres NOTIFY on the `stern_scheduled_operations_pending` channel
-- when a scheduled operation TRANSITIONS into the `pending` status — either
-- freshly inserted or moving back from another status (retry, requeue,
-- recovery from stuck `:in_progress`). Workers LISTENing on this channel can
-- wake from their poll loop immediately instead of waiting for the next tick.
--
-- v02 vs v01: v01 fired whenever NEW.status was pending, including on
-- UPDATEs that left the row already-pending (e.g.,
-- `update_all(status: :pending)` over a mix that included rows already
-- pending). Those notifies woke the runner for nothing — the row was
-- already eligible for pickup. v02 adds a transition guard
-- (`OLD.status IS DISTINCT FROM NEW.status`) so only true status changes
-- into pending generate a notify.
--
-- Enum encoding: ScheduledOperation's `status` column stores an integer
-- (Rails enum), where `pending` = 0. Keep this in sync with the Ruby enum
-- definition at app/models/stern/scheduled_operation.rb.
CREATE OR REPLACE FUNCTION stern_sop_notify() RETURNS trigger AS $$
BEGIN
  IF NEW.status = 0 AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    PERFORM pg_notify('stern_scheduled_operations_pending', NEW.id::text);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS stern_sop_notify_trigger ON stern_scheduled_operations;

CREATE TRIGGER stern_sop_notify_trigger
AFTER INSERT OR UPDATE OF status ON stern_scheduled_operations
FOR EACH ROW EXECUTE FUNCTION stern_sop_notify();
