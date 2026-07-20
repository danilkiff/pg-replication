# Specification

Educational repository demonstrating PostgreSQL 15 logical replication between two
instances: the happy path and its edge cases.

## Environment

- two `postgres:15` instances (latest 15.x minor) under Docker Compose: `publisher`
  (`wal_level = logical`) and `subscriber`;
- no host dependencies beyond Docker: all SQL runs via `docker compose exec psql`.

## Scenarios

Each scenario is a self-contained bash test with assertions, runnable individually
or all at once. Every test creates its own database pair, so runs are isolated.

Happy path:

- publication/subscription setup, initial table sync, then INSERT / UPDATE /
  DELETE / TRUNCATE flowing to the subscriber.

PostgreSQL 15 features:

- row filters: `CREATE PUBLICATION ... WHERE (...)`, including the update/delete
  restriction on non-replica-identity columns;
- column lists: publishing a subset of columns.

Failure and conflict cases:

- unique-constraint conflict on apply: `disable_on_error`, diagnosing via
  `pg_stat_subscription_stats` and logs, resolving with `ALTER SUBSCRIPTION ... SKIP`;
- WAL retention: subscriber down, replication slot holds WAL on the publisher,
  monitoring via `pg_replication_slots`, catch-up after restart;
- UPDATE/DELETE on a table without a replica identity: the error and the
  `REPLICA IDENTITY FULL` fix;
- schema drift: DDL is not replicated — a new publisher column breaks apply until
  added on the subscriber; sequences are not replicated either.

## Verification

- `make test` runs all scenarios, `make test-NN` runs one; green/red per assertion,
  non-zero exit on failure;
- GitHub Actions workflow runs the full suite on push (repository is local for now;
  the workflow activates once pushed to GitHub).

## Out of scope

- physical streaming replication;
- `streaming` / `two_phase` subscription options;
- bidirectional replication: safe same-table loop protection needs the `origin`
  subscription option, which arrived in PostgreSQL 16;
- orchestration beyond Docker Compose.
