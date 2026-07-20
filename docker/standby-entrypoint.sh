#!/bin/bash
# First start: seed a physical standby of $1 via pg_basebackup, then hand over
# to the command compose passes (postgres). Later starts skip the seeding.
# -R writes primary_conninfo/primary_slot_name and standby.signal; dbname is
# passed explicitly so -R records it — slot sync (PG17) logs in over
# primary_conninfo and needs a database there. The cluster GUCs need no
# handling: the primary keeps them in postgresql.auto.conf (init-primary.sh),
# which arrives with the basebackup.
set -e
primary=$1
shift

# 14_pg_createsubscriber parks the container: pg_createsubscriber requires the
# standby's postgres to be stopped, but the datadir is an anonymous volume
# that dies with the container — so the container must stay up, idle. The
# trap keeps `docker stop` fast (a signal-less PID 1 would eat the full grace
# period).
if [[ -e "/docker/hold-$primary" ]]; then
  trap 'exit 0' TERM
  sleep infinity &
  wait $!
  exit 0
fi

# -s: PG_VERSION exists and is non-empty, so a datadir half-written by an
# interrupted seeding attempt does not count as seeded
if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
  # --checkpoint=fast: the default spread checkpoint can take minutes on the
  # primary, and the container's healthcheck window is ~60s — compose up --wait
  # would declare the seeding standby dead while pg_basebackup idles
  until pg_basebackup -d "host=$primary port=5432 user=postgres dbname=postgres" \
        -D "$PGDATA" -R -X stream -S standby_slot --checkpoint=fast; do
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
