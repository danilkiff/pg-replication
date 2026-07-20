#!/usr/bin/env bash
# A published table without a primary key or replica identity accepts INSERTs,
# but UPDATE/DELETE fail on the publisher itself. REPLICA IDENTITY FULL fixes
# it: whole old rows are sent and the subscriber matches on all columns.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t06_replica_identity

sql $PUB $DB "CREATE TABLE events (id int, payload text)"
sql $SUB $DB "CREATE TABLE events (id int, payload text)"

sql $PUB $DB "CREATE PUBLICATION pub_ri FOR TABLE events"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t06 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_ri"
wait_sync $SUB $DB sub_t06

# INSERT needs no replica identity
sql $PUB $DB "INSERT INTO events VALUES (1, 'a'), (2, 'b')"
wait_value $SUB $DB "SELECT count(*) FROM events" 2 "INSERT works without replica identity"

risk expect_fail $PUB $DB "UPDATE events SET payload = 'c' WHERE id = 1" \
  "does not have a replica identity" \
  "UPDATE rejected on the publisher without replica identity"
risk expect_fail $PUB $DB "DELETE FROM events WHERE id = 2" \
  "does not have a replica identity" \
  "DELETE rejected on the publisher without replica identity"

sql $PUB $DB "ALTER TABLE events REPLICA IDENTITY FULL"

sql $PUB $DB "UPDATE events SET payload = 'c' WHERE id = 1"
sql $PUB $DB "DELETE FROM events WHERE id = 2"
wait_value $SUB $DB "SELECT payload FROM events WHERE id = 1" "c" "UPDATE works with REPLICA IDENTITY FULL"
wait_value $SUB $DB "SELECT count(*) FROM events" 1 "DELETE works with REPLICA IDENTITY FULL"

finish
