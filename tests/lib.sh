#!/usr/bin/env bash
# Shared harness for scenario tests. Each test calls `setup <db_name>` to get a
# fresh database pair, so a failed run cannot poison the next one.

set -euo pipefail

COMPOSE="docker compose"
PUB=publisher
SUB=subscriber
PUB_STANDBY=publisher-standby
SUB_STANDBY=subscriber-standby
# Connection strings used in CREATE SUBSCRIPTION; hosts resolve inside the compose network
conninfo() { echo "host=$1 port=5432 user=postgres password=postgres dbname=$2"; }
pub_conninfo() { conninfo publisher "$1"; }

_PASS=0

# sql <node> <db> <statement> — run SQL, print tuples only
sql() {
  local node=$1
  local db=$2
  local statement=$3
  $COMPOSE exec -T "$node" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$db" -Atc "$statement"
}

# Gentoo-style markers: green * ok, red * failure, orange ! for an assertion
# whose success confirms an operational risk
source tests/colors.sh

_RISK=0
ok() {
  _PASS=$((_PASS + 1))
  if (( _RISK )); then
    echo " ${ORANGE}!${RESET} $1"
  else
    echo " ${GREEN}*${RESET} $1"
  fi
}

fail() {
  echo " ${RED}*${RESET} FAIL: $1" >&2
  exit 1
}

# risk <assertion...> — wrap ok/assert_eq/wait_value/expect_fail whose success
# demonstrates an operational risk rather than a working feature
risk() {
  _RISK=1
  "$@"
  _RISK=0
}

# assert_eq <actual> <expected> <description>
assert_eq() {
  local actual=$1
  local expected=$2
  local desc=$3
  [[ "$actual" == "$expected" ]] || fail "$desc: expected '$expected', got '$actual'"
  ok "$desc"
}

# expect_fail <node> <db> <statement> <error-pattern> <description>
expect_fail() {
  local node=$1
  local db=$2
  local statement=$3
  local pattern=$4
  local desc=$5
  local out
  if out=$(sql "$node" "$db" "$statement" 2>&1); then
    fail "$desc: statement succeeded but an error was expected"
  fi
  grep -q "$pattern" <<<"$out" || fail "$desc: error does not match '$pattern': $out"
  ok "$desc"
}

# wait_value <node> <db> <query> <expected> <description> [timeout_s]
wait_value() {
  local node=$1
  local db=$2
  local query=$3
  local expected=$4
  local desc=$5
  local timeout=${6:-30}
  local deadline=$((SECONDS + timeout))
  local actual
  local err=''
  while true; do
    if actual=$(sql "$node" "$db" "$query" 2>&1); then
      err=''
    else
      err=$actual
      actual=''
    fi
    if [[ "$actual" == "$expected" ]]; then
      ok "$desc"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      local msg="$desc: timed out, last value '$actual', expected '$expected'"
      if [[ -n "$err" ]]; then
        msg="$msg, last error: $err"
      fi
      fail "$msg"
    fi
    sleep 0.5
  done
}

# wait_sync <node> <db> <subscription> — block until initial table sync is done
wait_sync() {
  local node=$1
  local db=$2
  local subname=$3
  wait_value "$node" "$db" \
    "SELECT count(*) FROM pg_subscription_rel r
       JOIN pg_subscription s ON s.oid = r.srsubid
      WHERE s.subname = '$subname' AND r.srsubstate <> 'r'" \
    0 "subscription $subname: initial sync finished" 60
}

# drop_subs <node> <db> — drop subscriptions left in db from a previous run
drop_subs() {
  local node=$1
  local db=$2
  local s
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
  local node=$1
  local db=$2
  local slot
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
  drop_subs $SUB "$DB"
  drop_db $PUB "$DB"
  drop_db $SUB "$DB"
  sql $PUB postgres "CREATE DATABASE $DB"
  sql $SUB postgres "CREATE DATABASE $DB"
}

# wait_streaming <primary> — physical standby attached and fully caught up.
# pg_stat_replication lists logical walsenders too; the physical one is told
# apart by the default walreceiver application_name.
wait_streaming() {
  local primary=$1
  wait_value "$primary" postgres \
    "SELECT count(*) FROM pg_stat_replication
      WHERE application_name = 'walreceiver' AND state = 'streaming'
        AND pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) = 0" \
    1 "physical standby of $primary is streaming and caught up" 120
}

# promote <standby> — promote and wait until it accepts writes
promote() {
  local standby=$1
  sql "$standby" postgres "SELECT pg_promote()" >/dev/null
  wait_value "$standby" postgres "SELECT pg_is_in_recovery()" f "$standby promoted" 60
}

# restore_pair <primary> <standby> [slot] — rebuild the pair after a failover
# scenario: discard the (possibly promoted) standby with its volume, restart
# the primary, re-seed the standby via pg_basebackup. The scenario's logical
# slot on the restored primary has no consumer anymore and would pin WAL for
# the rest of the suite — drop it.
restore_pair() {
  local primary=$1
  local standby=$2
  local slot=${3:-}
  $COMPOSE rm -sfv "$standby" >/dev/null 2>&1 || true
  if ! $COMPOSE up -d --wait "$primary" "$standby" >/dev/null 2>&1; then
    echo "restore_pair: failed to restore $primary/$standby, later scenarios will hit a dead pair" >&2
    return 0
  fi
  if [[ -n "$slot" ]]; then
    sql "$primary" postgres "SELECT pg_drop_replication_slot(slot_name)
                               FROM pg_replication_slots
                              WHERE slot_name = '$slot' AND NOT active" >/dev/null
  fi
}

finish() {
  echo "=== ${GREEN}PASSED${RESET} ($_PASS assertions)"
}
