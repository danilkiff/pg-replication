#!/usr/bin/env bash
# Failover slots (PG17): the anti-09. With failover = true on the
# subscription, sync_replication_slots on the standby copies the logical slot
# there, and synchronized_standby_slots on the primary refuses to send a
# transaction to the logical consumer before the physical standby has it — the
# subscriber can no longer get ahead. After an unplanned failover the synced
# slot is live on the promoted node and the subscription resumes with nothing
# lost: repointing the connection is the whole procedure.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t13_failover_slots
trap 'restore_pair $PUB $PUB_STANDBY sub_t13' EXIT

wait_streaming $PUB

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $SUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $PUB $DB "CREATE PUBLICATION pub_ha FOR TABLE t"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t13 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_ha
              WITH (failover = true)"
wait_sync $SUB $DB sub_t13

wait_value $PUB_STANDBY postgres \
  "SELECT count(*) FROM pg_replication_slots
    WHERE slot_name = 'sub_t13' AND synced AND NOT temporary
      AND invalidation_reason IS NULL" \
  1 "slot synced to the standby" 60

sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 100) g"
wait_value $SUB $DB "SELECT count(*) FROM t" 100 "baseline replicated"

# The 09 move: standby down, writes continue. There the subscriber ran ahead;
# here synchronized_standby_slots holds the batch back instead.
compose stop $PUB_STANDBY >/dev/null 2>&1
sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(101, 200) g"
sleep 5
assert_eq "$(sql $SUB $DB "SELECT count(*) FROM t")" 100 \
  "batch held back while the standby is down — no divergence window"

compose start $PUB_STANDBY >/dev/null 2>&1
wait_value $SUB $DB "SELECT count(*) FROM t" 200 "batch released once the standby caught up"

# The synced slot advances on its own schedule; the primary must not die
# before the standby's copy has covered the batch
lsn=$(sql $PUB $DB "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = 'sub_t13'")
wait_value $PUB_STANDBY postgres \
  "SELECT confirmed_flush_lsn >= '$lsn'::pg_lsn FROM pg_replication_slots
    WHERE slot_name = 'sub_t13'" t "synced slot caught up with the primary's" 60

compose kill $PUB >/dev/null 2>&1
promote $PUB_STANDBY

# The promoted node inherits synchronized_standby_slots but has no standby of
# its own, so its failover-slot walsenders would wait forever for a confirm
# from the nonexistent physical slot. Clearing it is part of the procedure.
sql $PUB_STANDBY postgres "ALTER SYSTEM SET synchronized_standby_slots = ''"
sql $PUB_STANDBY postgres "SELECT pg_reload_conf()" >/dev/null

assert_eq "$(sql $PUB_STANDBY postgres "SELECT count(*) FROM pg_replication_slots
                                         WHERE slot_name = 'sub_t13'")" 1 \
  "logical slot survived the failover"

sql $SUB $DB "ALTER SUBSCRIPTION sub_t13 DISABLE"
sql $SUB $DB "ALTER SUBSCRIPTION sub_t13 CONNECTION '$(conninfo $PUB_STANDBY $DB)'"
sql $SUB $DB "ALTER SUBSCRIPTION sub_t13 ENABLE"

sql $PUB_STANDBY $DB "INSERT INTO t VALUES (201, 'after-failover')"
wait_value $SUB $DB "SELECT count(*) FROM t" 201 "replication resumed on the synced slot"
assert_eq "$(sql $SUB $DB "SELECT count(*) FROM t WHERE id <= 200")" 200 \
  "no row lost, no divergence"

sql $SUB $DB "ALTER SUBSCRIPTION sub_t13 DISABLE"
finish
