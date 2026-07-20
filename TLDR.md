# TLDR

Seven scenarios against two `postgres:15` (15.18) nodes, all passing. The
experiment's core result: logical replication is not a transparent add-on —
publishing tables imposes contract obligations on the data source itself, and
each one is observable as a concrete failure when violated. A side finding:
same-table bidirectional replication is out of reach on PG15, since the
`origin` subscription option that breaks the loop arrived in PG16.

## Obligations on the data source

Each obligation is enforced by the scenario test named after it.

- capacity: the source runs with `wal_level = logical` and reserves
  `max_wal_senders` / `max_replication_slots` for every consumer; without this
  no subscription starts (docker-compose.yml, exercised by every scenario);
- replica identity: every published table receiving UPDATE/DELETE must have a
  primary key or replica identity — otherwise those statements fail on the
  source itself, breaking its own workload, not the consumer's
  (`tests/06_replica_identity.sh`);
- filtered publications are insert-only unless keyed: a row filter over
  non-replica-identity columns blocks UPDATE/DELETE on the source; the source
  either extends its replica identity or publishes inserts only
  (`tests/02_row_filter.sh`);
- disk headroom and slot monitoring: an unavailable consumer pins WAL on the
  source without bound; the source owns watching
  `pg_replication_slots` backlog and deciding when a dead slot gets dropped
  (`tests/05_wal_retention.sh`);
- coordinated schema changes: DDL does not replicate, so additive DDL must
  reach the consumer before the first row that uses it — otherwise apply halts
  and the WAL backlog starts growing (`tests/07_schema_drift.sh`);
- exclusive key space: replicated tables tolerate no consumer-local writes in
  the published key range; a collision stops apply, and recovery via
  `ALTER SUBSCRIPTION ... SKIP` silently discards a whole source transaction
  downstream — delivered does not mean applied (`tests/04_conflict_skip.sh`);
- destructive statements propagate: TRUNCATE on the source empties the
  consumer's table under the default publish list; the source must exclude it
  from the publication if consumers cannot accept that (`tests/01_basic.sh`);
- sequences are not part of the stream: the source cannot promise the consumer
  usable sequence state, so switchover procedures include a manual `setval`
  (`tests/07_schema_drift.sh`).
