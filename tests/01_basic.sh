#!/usr/bin/env bash
# Happy path: publication, subscription, initial sync, then INSERT / UPDATE /
# DELETE / TRUNCATE flowing from publisher to subscriber.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t01_basic

sql $PUB $DB "CREATE TABLE items (id int PRIMARY KEY, val text)"
sql $SUB $DB "CREATE TABLE items (id int PRIMARY KEY, val text)"

# Rows existing before the subscription are delivered by the initial table sync
sql $PUB $DB "INSERT INTO items SELECT g, 'seed-' || g FROM generate_series(1, 100) g"

sql $PUB $DB "CREATE PUBLICATION pub_basic FOR TABLE items"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t01 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_basic"
wait_sync $SUB $DB sub_t01

wait_value $SUB $DB "SELECT count(*) FROM items" 100 "initial sync copied pre-existing rows"

sql $PUB $DB "INSERT INTO items VALUES (101, 'insert')"
sql $PUB $DB "UPDATE items SET val = 'update' WHERE id = 1"
sql $PUB $DB "DELETE FROM items WHERE id = 2"

wait_value $SUB $DB "SELECT count(*) FROM items" 100 "INSERT and DELETE replicated"
wait_value $SUB $DB "SELECT val FROM items WHERE id = 1" "update" "UPDATE replicated"
wait_value $SUB $DB "SELECT count(*) FROM items WHERE id = 2" 0 "deleted row is gone"

# TRUNCATE is replicated too (publish option includes it by default)
sql $PUB $DB "TRUNCATE items"
wait_value $SUB $DB "SELECT count(*) FROM items" 0 "TRUNCATE replicated"

finish
