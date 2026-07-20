#!/usr/bin/env bash
# Logical decoding on a standby (PG16): the subscriber consumes the
# publication through the publisher's physical standby, offloading the
# primary. Slot creation on a standby waits for a running-xacts record that
# only the primary can write — pg_log_standby_snapshot() emits one on demand;
# without the pump below CREATE SUBSCRIPTION would sit until the primary's
# next checkpoint. hot_standby_feedback (docker/init-primary.sh) keeps the
# primary's vacuum from invalidating the standby's slot.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t12_standby_decoding
wait_streaming $PUB

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $SUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $PUB $DB "CREATE PUBLICATION pub_standby FOR TABLE t"
sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 50) g"
# the publication, table and rows must be replayed before the standby can
# serve them
wait_streaming $PUB

# One record per slot creation is needed (the subscription's own slot plus a
# tablesync slot), so a single call is not enough — pump until sync is done
(while true; do
   sql $PUB postgres "SELECT pg_log_standby_snapshot()" >/dev/null 2>&1 || true
   sleep 0.5
 done) &
trap 'kill %1 2>/dev/null || true' EXIT

sql $SUB $DB "CREATE SUBSCRIPTION sub_t12 CONNECTION '$(conninfo $PUB_STANDBY $DB)' PUBLICATION pub_standby"
wait_sync $SUB $DB sub_t12

assert_eq "$(sql $PUB_STANDBY postgres "SELECT pg_is_in_recovery()")" t \
  "decoding node is still a standby"
assert_eq "$(sql $PUB_STANDBY postgres "SELECT count(*) FROM pg_replication_slots
                                         WHERE slot_name = 'sub_t12'")" 1 \
  "logical slot lives on the standby"
assert_eq "$(sql $PUB postgres "SELECT count(*) FROM pg_replication_slots
                                 WHERE slot_name = 'sub_t12'")" 0 \
  "primary holds no slot for this subscription"
wait_value $SUB $DB "SELECT count(*) FROM t" 50 "initial sync flowed through the standby"

sql $PUB $DB "INSERT INTO t VALUES (51, 'streamed')"
wait_value $SUB $DB "SELECT count(*) FROM t" 51 "primary write decoded on the standby"

finish
