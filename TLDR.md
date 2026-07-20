# TLDR

Ten scenarios against a four-node `postgres:15` (15.18) stand — publisher and
subscriber, each an active-passive physical pair. The
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
- logical replication slots are not carried over by physical failover: the
  promoted source has no slot, and with a lagging standby the subscriber ends
  up ahead of the new source — divergence with no error anywhere
  (`tests/09_source_failover.sh`). Slot synchronization to a standby
  (`failover` slots, `sync_replication_slots`) arrived in
  [PG17](https://www.postgresql.org/docs/17/logical-replication-failover.html);
- a planned switchover is lossless on PG15: freeze writes, wait out both
  consumers, promote, recreate the slot, repoint the subscription
  (`tests/08_source_switchover.sh`);
- on the subscriber side the subscription and its origin progress do travel
  with the physical replica, but the publisher resumes at the slot's
  `confirmed_flush_lsn` — transactions the dead primary had confirmed are
  skipped silently (`tests/10_subscriber_failover.sh`).
