-- Fires a Postgres NOTIFY on the `stern_sop_pending` channel whenever a
-- scheduled operation enters the `pending` status (freshly inserted or
-- transitioned back from a retry). Workers LISTENing on this channel can
-- wake from their poll loop immediately instead of waiting for the next tick.
--
-- Enum encoding: ScheduledOperation's `status` column stores an integer
-- (Rails enum), where `pending` = 0. Keep this in sync with the Ruby enum
-- definition at app/models/stern/scheduled_operation.rb.
CREATE OR REPLACE FUNCTION stern_sop_notify() RETURNS trigger AS $$
BEGIN
  IF NEW.status = 0 THEN
    PERFORM pg_notify('stern_sop_pending', NEW.id::text);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS stern_sop_notify_trigger ON stern_scheduled_operations;

CREATE TRIGGER stern_sop_notify_trigger
AFTER INSERT OR UPDATE OF status ON stern_scheduled_operations
FOR EACH ROW EXECUTE FUNCTION stern_sop_notify();
