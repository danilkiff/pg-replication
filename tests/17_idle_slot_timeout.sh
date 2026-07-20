#!/usr/bin/env bash
# idle_replication_slot_timeout (PG18): the answer to scenario 05's open end.
# There an unavailable consumer pins WAL without bound and a human must notice
# and drop the slot; here the server invalidates an idle slot by itself.
# Invalidation happens during checkpoints, so the test forces one instead of
# waiting for checkpoint_timeout. The flip side: an invalidated slot is dead —
# the subscription cannot resume and needs a full resync.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t17_idle_timeout

# 1min is the smallest effective value; sighup, so a reload is enough
sql $PUB postgres "ALTER SYSTEM SET idle_replication_slot_timeout = '1min'"
sql $PUB postgres "SELECT pg_reload_conf()" >/dev/null
trap 'sql $PUB postgres "ALTER SYSTEM RESET idle_replication_slot_timeout"
      sql $PUB postgres "SELECT pg_reload_conf()" >/dev/null' EXIT

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $SUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $PUB $DB "CREATE PUBLICATION pub_idle FOR TABLE t"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t17 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_idle"
wait_sync $SUB $DB sub_t17

# Consumer goes away; the slot idles from this moment
sql $SUB $DB "ALTER SUBSCRIPTION sub_t17 DISABLE"
wait_value $PUB $DB "SELECT NOT active FROM pg_replication_slots WHERE slot_name = 'sub_t17'" t \
  "slot idle after the subscriber disconnected"

sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 100) g"

# Ride out the timeout, then force the checkpoint that applies it
sleep 65
sql $PUB postgres "CHECKPOINT"
risk wait_value $PUB $DB "SELECT invalidation_reason FROM pg_replication_slots
                           WHERE slot_name = 'sub_t17'" idle_timeout \
  "server invalidated the idle slot on its own" 90

# The slot is unusable; the worker dies at START_REPLICATION, before apply,
# so nothing shows in pg_stat_subscription_stats — only the log tells
# docker interprets a zoneless --since timestamp as client-local time
since=$(date +%Y-%m-%dT%H:%M:%S)
sql $SUB $DB "ALTER SUBSCRIPTION sub_t17 ENABLE"
wait_value $SUB $DB "SELECT count(*) FROM pg_stat_subscription
                      WHERE subname = 'sub_t17' AND pid IS NOT NULL" 0 \
  "apply worker cannot stay up" 60
idle_logs=$(compose logs $SUB --since "$since" 2>/dev/null)
grep -q 'invalidated due to "idle_timeout"' <<<"$idle_logs" \
  || fail "expected the idle_timeout invalidation error in the subscriber log"
risk ok "subscription cannot resume on an invalidated slot"

# Teardown: the dead subscription must detach from the dead slot
sql $SUB $DB "ALTER SUBSCRIPTION sub_t17 DISABLE"
sql $SUB $DB "ALTER SUBSCRIPTION sub_t17 SET (slot_name = NONE)"
sql $SUB $DB "DROP SUBSCRIPTION sub_t17"
sql $PUB postgres "SELECT pg_drop_replication_slot('sub_t17')" >/dev/null

finish
