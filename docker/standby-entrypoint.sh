#!/bin/bash
# First start: seed a physical standby of $1 via pg_basebackup (-R writes
# primary_conninfo/primary_slot_name and standby.signal), then hand over to
# the command compose passes (postgres). Later starts skip the seeding. The
# cluster GUCs need no handling: the primary keeps them in
# postgresql.auto.conf (init-primary.sh), which arrives with the basebackup.
set -e
primary=$1
shift
# -s: PG_VERSION exists and is non-empty, so a datadir half-written by an
# interrupted seeding attempt does not count as seeded
if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
  # --checkpoint=fast: the default spread checkpoint can take minutes on the
  # primary, and the container's healthcheck window is ~60s — compose up --wait
  # would declare the seeding standby dead while pg_basebackup idles
  until pg_basebackup -h "$primary" -U postgres -D "$PGDATA" -R -X stream -S standby_slot --checkpoint=fast; do
    echo "pg_basebackup from $primary failed, retrying"
    # PGDATA is a mountpoint: the directory itself cannot be removed, so
    # empty it instead of rm -rf
    find "$PGDATA" -mindepth 1 -delete
    sleep 2
  done
  chmod 700 "$PGDATA"
fi
# exec: postgres replaces this script as PID 1 and receives container signals
exec "$@"
