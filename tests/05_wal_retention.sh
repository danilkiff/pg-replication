#!/usr/bin/env bash
# WAL retention: while the subscriber is down, its replication slot pins WAL on
# the publisher and the backlog grows without bound (no max_slot_wal_keep_size
# here). Monitoring query: distance from current WAL position to the slot's
# confirmed_flush_lsn. After restart the subscriber catches up and the backlog
# collapses.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t05_wal_retention

# The subscriber must be running again even if an assertion fails mid-test
trap '$COMPOSE start $SUB >/dev/null 2>&1' EXIT

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, data text)"
sql $SUB $DB "CREATE TABLE t (id int PRIMARY KEY, data text)"

sql $PUB $DB "CREATE PUBLICATION pub_wal FOR TABLE t"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t05 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_wal"
wait_sync $SUB $DB sub_t05

backlog="SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
           FROM pg_replication_slots WHERE slot_name = 'sub_t05'"

$COMPOSE stop $SUB >/dev/null
wait_value $PUB $DB "SELECT active FROM pg_replication_slots WHERE slot_name = 'sub_t05'" f \
  "slot inactive while subscriber is down"

# ~30 MB of WAL the slot now has to retain
sql $PUB $DB "INSERT INTO t SELECT g, repeat('x', 1000) FROM generate_series(1, 30000) g"

retained=$(sql $PUB $DB "$backlog")
(( retained > 10 * 1024 * 1024 )) || fail "expected >10MB retained WAL, got $retained bytes"
ok "slot retains WAL while subscriber is down: $retained bytes"

$COMPOSE start $SUB >/dev/null
wait_value $SUB $DB "SELECT 1" 1 "subscriber is back" 60
wait_value $SUB $DB "SELECT count(*) FROM t" 30000 "subscriber caught up" 120
wait_value $PUB $DB "SELECT ($backlog) < 1024 * 1024" t "retained WAL released after catch-up" 60

finish
