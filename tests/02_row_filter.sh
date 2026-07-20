#!/usr/bin/env bash
# PG15 row filters: publication with a WHERE clause replicates only matching rows.
# Also shows the restriction: if the publication publishes UPDATE/DELETE, the
# filter may reference replica identity columns only.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t02_row_filter

sql $PUB $DB "CREATE TABLE orders (id int PRIMARY KEY, region text NOT NULL, amount int)"
sql $SUB $DB "CREATE TABLE orders (id int PRIMARY KEY, region text NOT NULL, amount int)"

# Filter on a non-key column is only allowed when the publication is insert-only:
# with the default publish list, UPDATE on the publisher would fail
sql $PUB $DB "CREATE PUBLICATION pub_all_dml FOR TABLE orders WHERE (region = 'eu')"
risk expect_fail $PUB $DB "UPDATE orders SET amount = 0" \
  "not part of the replica identity" \
  "UPDATE rejected: filter column is not part of the replica identity"
sql $PUB $DB "DROP PUBLICATION pub_all_dml"

sql $PUB $DB "CREATE PUBLICATION pub_eu FOR TABLE orders WHERE (region = 'eu')
              WITH (publish = 'insert')"

# The same statement is legal again: the identity restriction applies only to
# publications that publish UPDATE/DELETE
sql $PUB $DB "UPDATE orders SET amount = 0"
ok "UPDATE accepted under the insert-only publication"

sql $PUB $DB "INSERT INTO orders VALUES (1, 'eu', 10), (2, 'us', 20), (3, 'eu', 30)"

sql $SUB $DB "CREATE SUBSCRIPTION sub_t02 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_eu"
wait_sync $SUB $DB sub_t02

# Initial sync applies the filter as well
wait_value $SUB $DB "SELECT count(*) FROM orders" 2 "initial sync copied only matching rows"

sql $PUB $DB "INSERT INTO orders VALUES (4, 'eu', 40), (5, 'us', 50)"
wait_value $SUB $DB "SELECT string_agg(id::text, ',' ORDER BY id) FROM orders" "1,3,4" \
  "streamed inserts filtered by region"

assert_eq "$(sql $PUB $DB "SELECT count(*) FROM orders")" 5 "publisher keeps all rows"

finish
