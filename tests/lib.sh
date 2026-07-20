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
  local node=$1 db=$2
  $COMPOSE exec -T "$node" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$db" -Atc "$3"
}

# Gentoo-style markers: green * ok, red * failure, orange ! for an assertion
# whose success confirms an operational risk. Colored only when stdout is a
# color-capable terminal; orange needs 256 colors, otherwise falls back to
# yellow.
_G='' _R='' _O='' _N=''
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
  _colors=$(tput colors 2>/dev/null || echo 0)
  if (( _colors >= 8 )); then
    _G=$'\e[32;01m' _R=$'\e[31;01m' _O=$'\e[33;01m' _N=$'\e[0m'
    (( _colors >= 256 )) && _O=$'\e[38;5;208;01m'
  fi
fi

_RISK=0
ok() {
  _PASS=$((_PASS + 1))
  if (( _RISK )); then
    echo " ${_O}!${_N} $1"
  else
    echo " ${_G}*${_N} $1"
  fi
}

fail() {
  echo " ${_R}*${_N} FAIL: $1" >&2
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
  local deadline=$((SECONDS + timeout)) actual err=''
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
    (( SECONDS < deadline )) || fail "$desc: timed out, last value '$actual', expected '$expected'${err:+, last error: $err}"
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

# wait_streaming <primary> — physical standby attached and fully caught up.
# pg_stat_replication lists logical walsenders too; the physical one is told
# apart by the default walreceiver application_name.
wait_streaming() {
  wait_value "$1" postgres \
    "SELECT count(*) FROM pg_stat_replication
      WHERE application_name = 'walreceiver' AND state = 'streaming'
        AND pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) = 0" \
    1 "physical standby of $1 is streaming and caught up" 120
}

# promote <standby> — promote and wait until it accepts writes
promote() {
  sql "$1" postgres "SELECT pg_promote()" >/dev/null
  wait_value "$1" postgres "SELECT pg_is_in_recovery()" f "$1 promoted" 60
}

# restore_pair <primary> <standby> [slot] — rebuild the pair after a failover
# scenario: discard the (possibly promoted) standby with its volume, restart
# the primary, re-seed the standby via pg_basebackup. The scenario's logical
# slot on the restored primary has no consumer anymore and would pin WAL for
# the rest of the suite — drop it.
restore_pair() {
  $COMPOSE rm -sfv "$2" >/dev/null 2>&1 || true
  if ! $COMPOSE up -d --wait "$1" "$2" >/dev/null 2>&1; then
    echo "restore_pair: failed to restore $1/$2, later scenarios will hit a dead pair" >&2
    return 0
  fi
  if [[ -n "${3:-}" ]]; then
    sql "$1" postgres "SELECT pg_drop_replication_slot(slot_name)
                         FROM pg_replication_slots
                        WHERE slot_name = '$3' AND NOT active" >/dev/null
  fi
}

finish() {
  echo "=== ${_G}PASSED${_N} ($_PASS assertions)"
}
