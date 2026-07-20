#!/usr/bin/env bash
# DDL is not replicated. A column added only on the publisher breaks apply: the
# worker retries in a loop (subscription stays enabled, errors accumulate in
# pg_stat_subscription_stats) until the subscriber table is altered to match.
# Sequences are not replicated either — after a switchover they must be bumped
# manually.

cd "$(dirname "$0")/.." && source tests/lib.sh
setup t07_schema_drift

sql $PUB $DB "CREATE TABLE docs (id bigserial PRIMARY KEY, body text)"
sql $SUB $DB "CREATE TABLE docs (id bigserial PRIMARY KEY, body text)"

sql $PUB $DB "CREATE PUBLICATION pub_drift FOR TABLE docs"
sql $SUB $DB "CREATE SUBSCRIPTION sub_t07 CONNECTION '$(pub_conninfo $DB)' PUBLICATION pub_drift"
wait_sync $SUB $DB sub_t07

sql $PUB $DB "INSERT INTO docs (body) SELECT 'doc-' || g FROM generate_series(1, 5) g"
wait_value $SUB $DB "SELECT count(*) FROM docs" 5 "baseline replication works"

# --- schema drift ---
# docker interprets a zoneless --since timestamp as client-local time
since=$(date +%Y-%m-%dT%H:%M:%S)
sql $PUB $DB "ALTER TABLE docs ADD COLUMN extra int NOT NULL DEFAULT 0"
sql $PUB $DB "INSERT INTO docs (body, extra) VALUES ('drift', 1)"

risk wait_value $SUB $DB "SELECT apply_error_count > 0 FROM pg_stat_subscription_stats
                      WHERE subname = 'sub_t07'" t \
  "apply fails and retries, errors visible in pg_stat_subscription_stats"
# grep -q would SIGPIPE `docker logs` and trip pipefail — capture first
drift_logs=$(compose logs $SUB --since "$since" 2>/dev/null)
grep -q "missing replicated column" <<<"$drift_logs" \
  || fail "expected 'missing replicated column' in subscriber log"
ok "subscriber log names the missing column"

# The fix is ordinary DDL on the subscriber; the stuck transaction then applies
sql $SUB $DB "ALTER TABLE docs ADD COLUMN extra int NOT NULL DEFAULT 0"
wait_value $SUB $DB "SELECT count(*) FROM docs" 6 "apply recovered after adding the column"
wait_value $SUB $DB "SELECT extra FROM docs WHERE body = 'drift'" 1 "new column value arrived"

# --- sequences ---
risk assert_eq "$(sql $SUB $DB "SELECT coalesce(last_value, 0) FROM pg_sequences
                            WHERE sequencename = 'docs_id_seq'")" 0 \
  "subscriber sequence untouched by replication"

# Switchover preparation: bump the sequence past the replicated ids
sql $SUB $DB "SELECT setval('docs_id_seq', (SELECT max(id) FROM docs))" >/dev/null
assert_eq "$(sql $SUB $DB "INSERT INTO docs (body) VALUES ('local') RETURNING id")" 7 \
  "local insert works after setval"

finish
