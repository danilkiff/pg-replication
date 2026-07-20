#!/usr/bin/env bash
# Generated columns over logical replication (PG18): by default they are not
# published — a subscriber with its own generated column computes its own
# values, and a different expression silently produces different data. With
# publish_generated_columns = stored the publisher sends computed values, and
# the subscriber column must then be plain (applying into a generated column
# is an error).

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t16_generated

# Default: the column is not published, each side computes its own
sql $PUB $DB "CREATE TABLE price (id int PRIMARY KEY, net int,
              gross int GENERATED ALWAYS AS (net * 2) STORED)"
sql $SUB $DB "CREATE TABLE price (id int PRIMARY KEY, net int,
              gross int GENERATED ALWAYS AS (net * 3) STORED)"
sql $PUB $DB "CREATE PUBLICATION pub_gen_default FOR TABLE price"

# Published: computed values travel, the subscriber column is plain
sql $PUB $DB "CREATE TABLE price_pub (id int PRIMARY KEY, net int,
              gross int GENERATED ALWAYS AS (net * 2) STORED)"
sql $SUB $DB "CREATE TABLE price_pub (id int PRIMARY KEY, net int, gross int)"
sql $PUB $DB "CREATE PUBLICATION pub_gen_stored FOR TABLE price_pub
              WITH (publish_generated_columns = stored)"

sql $SUB $DB "CREATE SUBSCRIPTION sub_t16_default CONNECTION '$(pub_conninfo $DB)'
              PUBLICATION pub_gen_default"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t16_stored CONNECTION '$(pub_conninfo $DB)'
              PUBLICATION pub_gen_stored"
wait_sync $SUB $DB sub_t16_default
wait_sync $SUB $DB sub_t16_stored

sql $PUB $DB "INSERT INTO price (id, net) VALUES (1, 10)"
sql $PUB $DB "INSERT INTO price_pub (id, net) VALUES (1, 10)"

wait_value $SUB $DB "SELECT gross FROM price WHERE id = 1" 30 \
  "unpublished: subscriber computed its own expression"
risk assert_eq "$(sql $PUB $DB "SELECT gross FROM price WHERE id = 1")" 20 \
  "same row, different derived value on each side — silent divergence"

wait_value $SUB $DB "SELECT gross FROM price_pub WHERE id = 1" 20 \
  "published: the computed value arrived as plain data"

# The receiving column cannot be generated when the value is published
sql $SUB $DB "ALTER SUBSCRIPTION sub_t16_stored DISABLE"
sql $PUB $DB "INSERT INTO price_pub (id, net) VALUES (2, 50)"
sql $SUB $DB "ALTER TABLE price_pub DROP COLUMN gross"
sql $SUB $DB "ALTER TABLE price_pub ADD COLUMN gross int GENERATED ALWAYS AS (net * 2) STORED"
sql $SUB $DB "ALTER SUBSCRIPTION sub_t16_stored ENABLE"
wait_value $SUB $DB "SELECT apply_error_count > 0 FROM pg_stat_subscription_stats
                      WHERE subname = 'sub_t16_stored'" t \
  "applying into a generated column is an error, not a merge"

# Restore a working shape so teardown leaves no retry loop behind
sql $SUB $DB "ALTER SUBSCRIPTION sub_t16_stored DISABLE"
sql $SUB $DB "ALTER TABLE price_pub DROP COLUMN gross"
sql $SUB $DB "ALTER TABLE price_pub ADD COLUMN gross int"
sql $SUB $DB "ALTER SUBSCRIPTION sub_t16_stored ENABLE"
wait_value $SUB $DB "SELECT gross FROM price_pub WHERE id = 2" 100 \
  "apply recovered on a plain column"

finish
