#!/usr/bin/env bash
# PG15 column lists: publish a subset of columns. The subscriber table does not
# even have the excluded column. The list must include replica identity columns,
# so full DML works here (unlike non-key row filters).

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t03_column_list

sql $PUB $DB "CREATE TABLE users (id int PRIMARY KEY, name text, email text, password text)"
sql $SUB $DB "CREATE TABLE users (id int PRIMARY KEY, name text, email text)"

sql $PUB $DB "CREATE PUBLICATION pub_public_cols FOR TABLE users (id, name, email)"
sql $PUB $DB "INSERT INTO users VALUES (1, 'alice', 'alice@example.com', 'secret1')"

sql $SUB $DB "CREATE SUBSCRIPTION sub_t03 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_public_cols"
wait_sync $SUB $DB sub_t03

wait_value $SUB $DB "SELECT name FROM users WHERE id = 1" "alice" "initial sync without excluded column"

sql $PUB $DB "INSERT INTO users VALUES (2, 'bob', 'bob@example.com', 'secret2')"
sql $PUB $DB "UPDATE users SET name = 'alice2', password = 'secret3' WHERE id = 1"
sql $PUB $DB "DELETE FROM users WHERE id = 2"

wait_value $SUB $DB "SELECT name FROM users WHERE id = 1" "alice2" "UPDATE replicated without excluded column"
wait_value $SUB $DB "SELECT count(*) FROM users" 1 "INSERT and DELETE replicated"

assert_eq "$(sql $SUB $DB "SELECT count(*) FROM information_schema.columns
                            WHERE table_name = 'users' AND column_name = 'password'")" 0 \
  "password column never existed on the subscriber"

finish
