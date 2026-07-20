#!/usr/bin/env bash
# Planned source switchover: with writes frozen and both the physical standby
# and the logical consumer fully caught up, the publisher role moves to the
# standby without losing a row. The PG15 procedure: disable the subscription,
# promote, recreate the logical slot on the new primary (slots do not survive
# failover), repoint the subscription. No resync needed because nothing was
# written in between.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t09_switchover
trap 'restore_pair $PUB $PUB_STANDBY sub_t09' EXIT

wait_streaming $PUB

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $SUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $PUB $DB "CREATE PUBLICATION pub_ha FOR TABLE t"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t09 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_ha"
wait_sync $SUB $DB sub_t09

sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 100) g"
wait_value $SUB $DB "SELECT count(*) FROM t" 100 "subscriber caught up before switchover"

# Writes are frozen from here; wait until nobody lags behind the primary
wait_value $PUB $DB "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) = 0
                       FROM pg_replication_slots WHERE slot_name = 'sub_t09'" t \
  "logical consumer fully caught up"
wait_streaming $PUB

sql $SUB $DB "ALTER SUBSCRIPTION sub_t09 DISABLE"
$COMPOSE stop $PUB >/dev/null 2>&1
promote $PUB_STANDBY

sql $PUB_STANDBY $DB "SELECT pg_create_logical_replication_slot('sub_t09', 'pgoutput')" >/dev/null
sql $SUB $DB "ALTER SUBSCRIPTION sub_t09 CONNECTION '$(conninfo $PUB_STANDBY $DB)'"
sql $SUB $DB "ALTER SUBSCRIPTION sub_t09 ENABLE"

sql $PUB_STANDBY $DB "INSERT INTO t VALUES (101, 'after-switchover')"
wait_value $SUB $DB "SELECT count(*) FROM t" 101 "replication continues from the new primary"
assert_eq "$(sql $SUB $DB "SELECT count(*) FROM t WHERE id <= 100")" 100 \
  "no row lost across the switchover"

sql $SUB $DB "ALTER SUBSCRIPTION sub_t09 DISABLE"
finish
