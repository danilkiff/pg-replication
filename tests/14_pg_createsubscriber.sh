#!/usr/bin/env bash
# pg_createsubscriber (PG17): converts a stopped physical standby into a
# logical replica in place — the data is already there via physical replay, so
# there is no initial copy. The tool promotes the node, creates the
# publication/slot on the source and the subscription on the target, advances
# the replication origin to the promotion point, and gives the node a new
# system identifier. The container is parked (hold file + restart) because
# the tool needs the postgres process stopped but the datadir alive.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t14_createsub

cleanup() {
  rm -f docker/hold-publisher
  # the tool drops the source's physical slot (primary_slot_name) during
  # conversion; restore_pair's pg_basebackup needs it back
  if [[ $(sql $PUB postgres "SELECT count(*) FROM pg_replication_slots
                              WHERE slot_name = 'standby_slot'") == 0 ]]; then
    sql $PUB postgres "SELECT pg_create_physical_replication_slot('standby_slot')" >/dev/null
  fi
  restore_pair $PUB $PUB_STANDBY sub_t14
}
trap cleanup EXIT

wait_streaming $PUB

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 100) g"
wait_streaming $PUB

before_id=$(sql $PUB_STANDBY postgres "SELECT system_identifier FROM pg_control_system()")

# Park the standby's container with postgres stopped, datadir intact
touch docker/hold-publisher
compose stop $PUB_STANDBY >/dev/null 2>&1
compose start $PUB_STANDBY >/dev/null 2>&1

# The tool restarts the target with the datadir's config only; the GUCs are
# there because the whole cluster config travels in postgresql.auto.conf
# (init-primary.sh).
# -w /tmp: the tool puts the target's unix socket into the current directory,
# and / is not writable for postgres
compose exec -w /tmp -T $PUB_STANDBY pg_createsubscriber \
  -D /var/lib/postgresql/data \
  -d $DB \
  -P "host=publisher port=5432 user=postgres password=postgres dbname=postgres" \
  --subscription=sub_t14 --publication=pub_t14 --replication-slot=sub_t14 \
  --recovery-timeout=120 >/dev/null 2>&1 \
  || fail "pg_createsubscriber failed"
ok "pg_createsubscriber converted the standby"

# Unpark: the same datadir now boots as a standalone logical replica
rm -f docker/hold-publisher
compose stop $PUB_STANDBY >/dev/null 2>&1
compose start $PUB_STANDBY >/dev/null 2>&1
wait_value $PUB_STANDBY postgres "SELECT 1" 1 "converted node is up" 60

assert_eq "$(sql $PUB_STANDBY postgres "SELECT pg_is_in_recovery()")" f \
  "converted node is no longer a standby"
assert_eq "$(sql $PUB_STANDBY $DB "SELECT count(*) FROM t")" 100 \
  "data came over physically — no initial copy"
wait_value $PUB_STANDBY $DB "SELECT count(*) FROM pg_subscription
                              WHERE subname = 'sub_t14' AND subenabled" 1 \
  "subscription created and enabled"

sql $PUB $DB "INSERT INTO t VALUES (101, 'post-conversion')"
wait_value $PUB_STANDBY $DB "SELECT count(*) FROM t" 101 \
  "changes now arrive via logical replication"

after_id=$(sql $PUB_STANDBY postgres "SELECT system_identifier FROM pg_control_system()")
[[ "$before_id" != "$after_id" ]] || fail "system identifier unchanged"
ok "new system identifier — the node left the physical pair for good"

finish
