#!/usr/bin/env bash
# Same-table bidirectional replication (PG16): each side subscribes to the
# other with origin = none, so a node sends only changes that originated
# locally — a row written by an apply worker carries the subscription's origin
# and is filtered out on the way back, which is what breaks the loop. Setup
# order matters: the side holding data syncs over with copy_data, the reverse
# subscription starts with copy_data = false or it would duplicate the
# baseline.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t11_bidi

sql $PUB $DB "CREATE TABLE t (id int PRIMARY KEY, src text)"
sql $SUB $DB "CREATE TABLE t (id int PRIMARY KEY, src text)"
sql $PUB $DB "CREATE PUBLICATION pub_bidi FOR TABLE t"
sql $SUB $DB "CREATE PUBLICATION pub_bidi FOR TABLE t"

sql $PUB $DB "INSERT INTO t VALUES (1, 'pub-baseline')"

sql $SUB $DB "CREATE SUBSCRIPTION sub_t11_fwd CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_bidi
              WITH (origin = none)"
wait_sync $SUB $DB sub_t11_fwd
wait_value $SUB $DB "SELECT count(*) FROM t" 1 "baseline synced forward"

sql $PUB $DB "CREATE SUBSCRIPTION sub_t11_rev CONNECTION '$(conninfo $SUB $DB)' PUBLICATION pub_bidi
              WITH (origin = none, copy_data = false)"

sql $PUB $DB "INSERT INTO t VALUES (2, 'from-pub')"
wait_value $SUB $DB "SELECT src FROM t WHERE id = 2" from-pub "publisher row reached subscriber"
sql $SUB $DB "INSERT INTO t VALUES (3, 'from-sub')"
wait_value $PUB $DB "SELECT src FROM t WHERE id = 3" from-sub "subscriber row reached publisher"

# Echo detection rides on stream ordering: an echoed row would precede these
# marker rows in its stream, collide on the PK and stall apply before the
# marker lands. Marker delivered + zero apply errors == nothing echoed.
sql $PUB $DB "INSERT INTO t VALUES (4, 'flush')"
wait_value $SUB $DB "SELECT count(*) FROM t" 4 "no echo on the subscriber"
assert_eq "$(sql $PUB $DB "SELECT count(*) FROM t")" 4 "no echo on the publisher"
assert_eq "$(sql $SUB $DB "SELECT coalesce(sum(apply_error_count), 0)
                             FROM pg_stat_subscription_stats WHERE subname = 'sub_t11_fwd'")" 0 \
  "forward apply is error-free"
assert_eq "$(sql $PUB $DB "SELECT coalesce(sum(apply_error_count), 0)
                             FROM pg_stat_subscription_stats WHERE subname = 'sub_t11_rev'")" 0 \
  "reverse apply is error-free"

finish
