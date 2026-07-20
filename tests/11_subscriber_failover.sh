#!/usr/bin/env bash
# Subscriber-side failover: the subscription and its replication-origin
# progress are ordinary catalog/WAL state, so they travel to the standby
# physically and apply resumes by itself after promotion. But if the standby
# lagged, the publisher restarts the stream at the slot's confirmed_flush_lsn,
# not at the promoted node's origin progress — the transactions in between are
# skipped silently, with no error raised on either side.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t11_sub_failover
trap 'restore_pair $SUB $SUB_STANDBY' EXIT

wait_streaming $SUB

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $SUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $PUB $DB "CREATE PUBLICATION pub_ha FOR TABLE t"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t11 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_ha"
wait_sync $SUB $DB sub_t11

sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 100) g"
wait_value $SUB $DB "SELECT count(*) FROM t" 100 "baseline applied on the subscriber"
wait_streaming $SUB

# Standby falls behind; the subscriber keeps applying and confirming
$COMPOSE stop $SUB_STANDBY >/dev/null 2>&1
sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(101, 200) g"
wait_value $SUB $DB "SELECT count(*) FROM t" 200 "subscriber applied the batch the standby missed"
# The skip only happens once the apply worker has reported the flush upstream —
# feedback is periodic, so wait for the slot to move past the batch
wait_value $PUB $DB "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) = 0
                       FROM pg_replication_slots WHERE slot_name = 'sub_t11'" t \
  "publisher slot confirmed past the batch" 60

$COMPOSE kill $SUB >/dev/null 2>&1
# --no-deps: plain `compose start` would resurrect the killed primary
$COMPOSE up -d --no-deps $SUB_STANDBY >/dev/null 2>&1
wait_value $SUB_STANDBY postgres "SELECT 1" 1 "standby back up" 60
promote $SUB_STANDBY

wait_value $SUB_STANDBY $DB "SELECT count(*) FROM pg_subscription
                              WHERE subname = 'sub_t11' AND subenabled" 1 \
  "subscription survived the failover and is enabled"

sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(201, 300) g"
wait_value $SUB_STANDBY $DB "SELECT count(*) FROM t WHERE id > 200" 100 \
  "new changes flow to the promoted subscriber"

risk assert_eq "$(sql $SUB_STANDBY $DB "SELECT count(*) FROM t WHERE id BETWEEN 101 AND 200")" 0 \
  "batch confirmed by the dead primary was skipped silently"
risk wait_value $SUB_STANDBY $DB "SELECT count(*) FROM pg_stat_subscription
                              WHERE subname = 'sub_t11' AND pid IS NOT NULL" 1 \
  "apply worker keeps running — the gap raised no error"

sql $SUB_STANDBY $DB "ALTER SUBSCRIPTION sub_t11 DISABLE"
finish
