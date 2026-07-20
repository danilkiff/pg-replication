#!/usr/bin/env bash
# Shared harness for scenario tests. Each test calls `setup <db_name>` to get a
# fresh database pair, so a failed run cannot poison the next one.

set -euo pipefail

COMPOSE="docker compose"
PUB=publisher
SUB=subscriber
# Connection string used in CREATE SUBSCRIPTION; resolves inside the compose network
pub_conninfo() { echo "host=publisher port=5432 user=postgres password=postgres dbname=$1"; }

_PASS=0

# sql <node> <db> <statement> — run SQL, print tuples only
sql() {
  local node=$1 db=$2
  $COMPOSE exec -T "$node" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$db" -Atc "$3"
}

ok() {
  _PASS=$((_PASS + 1))
  echo "  ok: $1"
}

fail() {
  echo "  FAIL: $1" >&2
  exit 1
}

# assert_eq <actual> <expected> <description>
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
  ok "$3"
}

# expect_fail <node> <db> <statement> <error-pattern> <description>
expect_fail() {
  local out
  if out=$(sql "$1" "$2" "$3" 2>&1); then
    fail "$5: statement succeeded but an error was expected"
  fi
  grep -q "$4" <<<"$out" || fail "$5: error does not match '$4': $out"
  ok "$5"
}

# wait_value <node> <db> <query> <expected> <description> [timeout_s]
wait_value() {
  local node=$1 db=$2 query=$3 expected=$4 desc=$5 timeout=${6:-30}
  local deadline=$((SECONDS + timeout)) actual
  while true; do
    actual=$(sql "$node" "$db" "$query" 2>/dev/null || true)
    if [[ "$actual" == "$expected" ]]; then
      ok "$desc"
      return 0
    fi
    (( SECONDS < deadline )) || fail "$desc: timed out, last value '$actual', expected '$expected'"
    sleep 0.5
  done
}

# wait_sync <node> <db> <subscription> — block until initial table sync is done
wait_sync() {
  wait_value "$1" "$2" \
    "SELECT count(*) FROM pg_subscription_rel r
       JOIN pg_subscription s ON s.oid = r.srsubid
      WHERE s.subname = '$3' AND r.srsubstate <> 'r'" \
    0 "subscription $3: initial sync finished" 60
}

# drop_subs <node> <db> — drop subscriptions left in db from a previous run
drop_subs() {
  local node=$1 db=$2 s
  [[ $(sql "$node" postgres "SELECT 1 FROM pg_database WHERE datname = '$db'") == 1 ]] || return 0
  for s in $(sql "$node" "$db" "SELECT subname FROM pg_subscription
                                 WHERE subdbid = (SELECT oid FROM pg_database WHERE datname = '$db')"); do
    sql "$node" "$db" "ALTER SUBSCRIPTION $s DISABLE"
    sql "$node" "$db" "ALTER SUBSCRIPTION $s SET (slot_name = NONE)"
    sql "$node" "$db" "DROP SUBSCRIPTION $s"
  done
}

# drop_db <node> <db> — drop db plus replication slots a dead subscription left behind
drop_db() {
  local node=$1 db=$2 slot
  if [[ $(sql "$node" postgres "SELECT 1 FROM pg_database WHERE datname = '$db'") == 1 ]]; then
    sql "$node" postgres "DROP DATABASE $db WITH (FORCE)"
  fi
  for slot in $(sql "$node" postgres "SELECT slot_name FROM pg_replication_slots
                                       WHERE database = '$db' AND NOT active"); do
    sql "$node" postgres "SELECT pg_drop_replication_slot('$slot')"
  done
}

# setup <db_name> — fresh database pair on both nodes; sets $DB for the test
setup() {
  DB=$1
  echo "=== $(basename "$0"): $DB"
  drop_subs $PUB "$DB"
  drop_subs $SUB "$DB"
  drop_db $PUB "$DB"
  drop_db $SUB "$DB"
  sql $PUB postgres "CREATE DATABASE $DB"
  sql $SUB postgres "CREATE DATABASE $DB"
}

finish() {
  echo "=== PASSED ($_PASS assertions)"
}
