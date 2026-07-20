#!/bin/bash
# Physical replication access for the standby: an hba entry (the image default
# "host all all all" does not match replication connections) plus a slot so
# the primary retains WAL while its standby is down.
set -e
echo "host replication all all scram-sha-256" >> "$PGDATA/pg_hba.conf"
psql -v ON_ERROR_STOP=1 -U postgres -c "SELECT pg_create_physical_replication_slot('standby_slot')"
