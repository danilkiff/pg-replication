# PostgreSQL 17 logical replication scenarios

Four `postgres:17.10` containers under Docker Compose — `publisher` and
`subscriber`, each with a physical standby for the failover and
standby-decoding scenarios — and a
set of self-contained test scripts demonstrating logical replication: the
happy path and the edge cases people actually hit. Each scenario is executable,
runs in its own database pair, and asserts what it claims.

Requires Docker only; all SQL runs inside the containers. `make` prints the
available targets; `make test` runs everything, `make test-04` runs one
scenario. Instances are exposed on localhost ports 5433 (publisher), 5434
(subscriber), 5435/5436 (their standbys), password `postgres`, for manual
poking.

## Scenarios

- `01_basic` — publication, subscription, initial sync, INSERT / UPDATE /
  DELETE / TRUNCATE flow;
- `02_row_filter` — publication `WHERE` clause (PG15), and why UPDATE fails
  when the filter uses a non-replica-identity column;
- `03_column_list` — publishing a subset of columns (PG15), subscriber table
  without the secret column;
- `04_conflict_skip` — duplicate key on apply, `disable_on_error`, finding the
  finish LSN in the log, `ALTER SUBSCRIPTION ... SKIP` (PG15);
- `05_wal_retention` — subscriber down: the slot pins WAL on the publisher;
  monitoring the backlog, catch-up after restart;
- `06_replica_identity` — UPDATE/DELETE rejected on a table without a replica
  identity, fixed by `REPLICA IDENTITY FULL`;
- `07_schema_drift` — DDL is not replicated: a new publisher column breaks
  apply until added on the subscriber; sequences are not replicated either;
- `08_source_switchover` — planned switchover of the source to its physical
  standby without losing a row: freeze writes, promote, recreate the slot,
  repoint the subscription;
- `09_source_failover` — unplanned source failover with a lagging standby:
  the slot is gone and the subscriber ends up ahead of the new source;
- `10_subscriber_failover` — the subscription survives the subscriber's own
  failover, but transactions the dead primary confirmed are silently skipped;
- `11_origin_filter` — same-table bidirectional replication with
  [`origin = none`](https://www.postgresql.org/docs/16/sql-createsubscription.html)
  (PG16): both sides publish and subscribe, locally-originated changes only,
  no loop;
- `12_standby_decoding` — logical decoding on a standby (PG16): the
  subscription feeds off the publisher's physical standby;
  `pg_log_standby_snapshot()` unblocks slot creation;
- `13_failover_slots` — failover slots (PG17), the counter-scenario to 09:
  `failover = true` plus `sync_replication_slots` and
  `synchronized_standby_slots` survive an unplanned source failover with no
  divergence;
- `14_pg_createsubscriber` — `pg_createsubscriber` (PG17) converts a stopped
  physical standby into a logical replica in place: no initial copy, new
  system identifier.

## Out of scope

- physical streaming replication as a topic of its own: the standbys exist to
  serve the failover and standby-decoding scenarios;
- `streaming` / `two_phase` subscription options;
- orchestration beyond Docker Compose.

TLDR.md sums up the contract obligations the scenarios demonstrate and the
version limitations around physical HA. Scenario scripts in `tests/` are the
documentation: each starts with a comment explaining the behavior it
demonstrates, then shows it in runnable SQL.
