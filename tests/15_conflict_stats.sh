#!/usr/bin/env bash
# Named apply conflicts (PG18): each conflict is logged with its type and
# counted in a dedicated pg_stat_subscription_stats column. update_missing and
# delete_missing are not errors — the change is skipped and replication moves
# on, which is exactly why they need counters to be noticed at all.
# insert_exists still fails apply and retries until resolved.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t15_conflicts

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $SUB $DB "CREATE TABLE t (id int PRIMARY KEY, v text)"
sql $PUB $DB "CREATE PUBLICATION pub_conflicts FOR TABLE t"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t15 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_conflicts"
wait_sync $SUB $DB sub_t15

sql $PUB $DB "INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 5) g"
wait_value $SUB $DB "SELECT count(*) FROM t" 5 "baseline replicated"

# docker interprets a zoneless --since timestamp as client-local time
since=$(date +%Y-%m-%dT%H:%M:%S)

# Local deletes the publisher knows nothing about; its UPDATE and DELETE then
# find no row to apply to
sql $SUB $DB "DELETE FROM t WHERE id IN (3, 4)"
sql $PUB $DB "UPDATE t SET v = 'updated' WHERE id = 3"
sql $PUB $DB "DELETE FROM t WHERE id = 4"

risk wait_value $SUB $DB "SELECT confl_update_missing FROM pg_stat_subscription_stats
                           WHERE subname = 'sub_t15'" 1 \
  "UPDATE with no local row skipped and counted (update_missing)"
risk wait_value $SUB $DB "SELECT confl_delete_missing FROM pg_stat_subscription_stats
                           WHERE subname = 'sub_t15'" 1 \
  "DELETE with no local row skipped and counted (delete_missing)"
assert_eq "$(sql $SUB $DB "SELECT apply_error_count FROM pg_stat_subscription_stats
                            WHERE subname = 'sub_t15'")" 0 \
  "neither missing-row conflict raised an error"

# insert_exists: the classic duplicate key, still an error, now named
sql $SUB $DB "INSERT INTO t VALUES (10, 'local')"
sql $PUB $DB "INSERT INTO t VALUES (10, 'remote')"
wait_value $SUB $DB "SELECT confl_insert_exists > 0 FROM pg_stat_subscription_stats
                      WHERE subname = 'sub_t15'" t \
  "duplicate key counted (insert_exists)"

# The conflict log line names the type and carries the replica identity of
# the losing tuple
conflict_logs=$(compose logs $SUB --since "$since" 2>/dev/null)
grep -q 'conflict detected on relation "public.t"' <<<"$conflict_logs" \
  || fail "expected a named conflict line in the subscriber log"
for c in update_missing delete_missing insert_exists; do
  grep -q "$c" <<<"$conflict_logs" || fail "conflict type $c not named in the log"
done
ok "all three conflicts named in the subscriber log"

# Resolution: remove the local row and the retried INSERT applies
sql $SUB $DB "DELETE FROM t WHERE id = 10"
wait_value $SUB $DB "SELECT v FROM t WHERE id = 10" remote "apply recovered after resolution"

finish
