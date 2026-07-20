#!/usr/bin/env bash
# Unplanned source failover with a lagging standby (here: stopped outright).
# The logical consumer keeps confirming transactions the standby never
# received, so after promotion the subscriber is AHEAD of the new source and
# the logical slot is gone — the subscription cannot resume. Before PG17
# nothing ties the logical consumer to the physical pair (PG17 adds
# synchronized_standby_slots for exactly this).

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t09_failover
trap 'restore_pair $PUB $PUB_STANDBY sub_t09' EXIT

wait_streaming $PUB

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $SUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $PUB $DB "CREATE PUBLICATION pub_ha FOR TABLE t"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t09 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_ha"
wait_sync $SUB $DB sub_t09

sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 100) g"
wait_value $SUB $DB "SELECT count(*) FROM t" 100 "baseline replicated everywhere"
wait_streaming $PUB

# Standby falls behind; the logical consumer keeps going
compose stop $PUB_STANDBY >/dev/null 2>&1
sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(101, 200) g"
wait_value $SUB $DB "SELECT count(*) FROM t" 200 "subscriber confirmed the batch the standby missed"

compose kill $PUB >/dev/null 2>&1
# --no-deps: plain `compose start` would resurrect the killed primary
compose up -d --no-deps $PUB_STANDBY >/dev/null 2>&1
wait_value $PUB_STANDBY postgres "SELECT 1" 1 "standby back up" 60
promote $PUB_STANDBY

risk assert_eq "$(sql $PUB_STANDBY $DB "SELECT count(*) FROM t")" 100 \
  "promoted source lacks the last batch"
risk assert_eq "$(sql $SUB $DB "SELECT count(*) FROM t")" 200 \
  "subscriber is ahead of the new source: divergence"
risk assert_eq "$(sql $PUB_STANDBY $DB "SELECT count(*) FROM pg_replication_slots")" 0 \
  "logical slot did not survive the failover"

sql $SUB $DB "ALTER SUBSCRIPTION sub_t09 DISABLE"
finish
