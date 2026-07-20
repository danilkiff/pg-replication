# TLDR

Seven scenarios against two `postgres:15` (15.18) nodes, all passing. The
experiment's core result: logical replication is not a transparent add-on —
publishing tables imposes contract obligations on the data source itself, and
each one is observable as a concrete failure when violated. A side finding:
same-table bidirectional replication is out of reach on PG15, since the
[`origin` subscription option](https://www.postgresql.org/docs/16/sql-createsubscription.html)
that breaks the loop arrived in PG16.

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

## Interaction with physical active-passive HA

Logical replication on the source composes with physical streaming, but not
transparently on PG15:

- [`wal_level = logical`](https://www.postgresql.org/docs/15/runtime-config-wal.html#GUC-WAL-LEVEL)
  is not the default (`replica`) and takes a restart, so both nodes of an HA
  pair need it configured up front — the level cannot be raised at promote
  time;
- `logical` is a superset of `replica`: physical streaming from the same
  primary keeps working, at the cost of extra WAL volume;
- a PG15 standby cannot run logical decoding, so the passive node cannot serve
  logical consumers until promoted; lifted in
  [PG16](https://www.postgresql.org/docs/release/16.0/);
- logical replication slots are not carried over by physical failover: after
  promotion every subscriber has to recreate its slot and resynchronize. Slot
  synchronization to a standby (`failover` slots, `sync_replication_slots`)
  arrived in
  [PG17](https://www.postgresql.org/docs/17/logical-replication-failover.html).
