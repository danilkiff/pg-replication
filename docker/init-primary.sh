#!/bin/bash
# Physical replication access for the standby: an hba entry (the image default
# "host all all all" does not match replication connections) plus a slot so
# the primary retains WAL while its standby is down.
set -e
echo "host replication all all scram-sha-256" >> "$PGDATA/pg_hba.conf"

# All cluster configuration goes through ALTER SYSTEM into the datadir, never
# the compose command line: the standby inherits the datadir via
# pg_basebackup, and tools that restart a node from its datadir alone see the
# same config.
#
# Both primaries get the union of sender and receiver needs; the subscriber
# publishes too (11), so the split would buy nothing.
# - sender limits: scenario databases stay around for inspection after the
#   suite, each holding a live replication slot;
# - receiver limits: apply workers count against max_worker_processes and
#   max_logical_replication_workers, and defaults (8/4) stall initial sync
#   once a few scenario subscriptions run concurrently; max_replication_slots
#   also sizes the replication-origin state pool — one origin per
#   subscription;
# - hot_standby_feedback acts only on the standby: without it the primary's
#   vacuum can invalidate the standby's logical slot (12).
psql -v ON_ERROR_STOP=1 -U postgres <<'SQL'
SELECT pg_create_physical_replication_slot('standby_slot');
ALTER SYSTEM SET wal_level = logical;
ALTER SYSTEM SET max_wal_senders = 20;
ALTER SYSTEM SET max_replication_slots = 20;
ALTER SYSTEM SET max_worker_processes = 32;
ALTER SYSTEM SET max_logical_replication_workers = 16;
ALTER SYSTEM SET hot_standby_feedback = on;
SQL
