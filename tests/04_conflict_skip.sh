#!/usr/bin/env bash
# Apply conflict: a local row on the subscriber collides with a replicated
# INSERT. With disable_on_error the subscription turns itself off instead of
# retrying forever. Recovery: read the failed transaction's finish LSN from the
# subscriber log, ALTER SUBSCRIPTION ... SKIP past it (new in PG15), re-enable.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t04_conflict

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $SUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"

sql $PUB $DB "CREATE PUBLICATION pub_conflict FOR TABLE t"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t04 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_conflict
              WITH (disable_on_error = true)"
wait_sync $SUB $DB sub_t04

# Local write the publisher knows nothing about — the future conflict
sql $SUB $DB "INSERT INTO t VALUES (1, 'local')"

# docker interprets a zoneless --since timestamp as client-local time
since=$(date +%Y-%m-%dT%H:%M:%S)
sql $PUB $DB "INSERT INTO t VALUES (1, 'remote')"

risk wait_value $SUB $DB "SELECT subenabled FROM pg_subscription WHERE subname = 'sub_t04'" f \
  "duplicate key stopped the subscription (disable_on_error)"
wait_value $SUB $DB "SELECT apply_error_count > 0 FROM pg_stat_subscription_stats
                      WHERE subname = 'sub_t04'" t \
  "error counted in pg_stat_subscription_stats"

# The log line carries the LSN needed for SKIP:
#   ... for replication target relation "public.t" in transaction N, finished at 0/XXXXXXX
lsn=$(compose logs $SUB --since "$since" 2>/dev/null \
      | grep -oE 'finished at [0-9A-F]+/[0-9A-F]+' | tail -1 | awk '{print $3}')
[[ -n "$lsn" ]] || fail "finish LSN not found in subscriber log"
ok "finish LSN extracted from log: $lsn"

sql $SUB $DB "ALTER SUBSCRIPTION sub_t04 SKIP (lsn = '$lsn')"
sql $SUB $DB "ALTER SUBSCRIPTION sub_t04 ENABLE"

# Replication moves on; the skipped transaction is lost, the local row survives
sql $PUB $DB "INSERT INTO t VALUES (2, 'after-conflict')"
wait_value $SUB $DB "SELECT v FROM t WHERE id = 2" "after-conflict" "replication resumed after SKIP"
risk assert_eq "$(sql $SUB $DB "SELECT v FROM t WHERE id = 1")" "local" \
  "conflicting transaction skipped, local row intact"

# disable_on_error served the demonstration; left on, it would also trip on
# connection loss when the ha scenarios take the publisher down, leaving a
# disabled subscription whose slot pins WAL on the publisher
sql $SUB $DB "ALTER SUBSCRIPTION sub_t04 SET (disable_on_error = false)"

finish
