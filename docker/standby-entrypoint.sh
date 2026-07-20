#!/bin/bash
# First start: seed a physical standby of $1 via pg_basebackup (-R writes
# primary_conninfo/primary_slot_name and standby.signal), then run postgres
# with the flags compose passes. Later starts skip the seeding.
set -e
primary=$1
shift
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  until pg_basebackup -h "$primary" -U postgres -D "$PGDATA" -R -X stream -S standby_slot; do
    echo "pg_basebackup from $primary failed, retrying"
    find "$PGDATA" -mindepth 1 -delete
    sleep 2
  done
  chmod 700 "$PGDATA"
fi
exec postgres "$@"
