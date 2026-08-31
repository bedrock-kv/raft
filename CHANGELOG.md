# Changelog

## Unreleased

### Added
- Development benchmarks under `bench/`: an in-process three-node cluster
  simulator (`bench/sim.exs`) and log/leader micro-benchmarks
  (`bench/micro.exs`) used to quantify replication behavior.
- `Bedrock.Raft.new/5` accepts an `:append_entries_batch_size` option that
  bounds how many transactions the leader puts into a single AppendEntries
  request. The default remains 10, so behavior is unchanged unless the option
  is given. Larger batches amortize round trips while a follower is catching
  up, at the cost of larger messages.

### Changed
- `Bedrock.Raft.Log` implementations must now provide `voted_for/1` and
  `save_election_state/3`. The latter must atomically persist Raft's
  `currentTerm` and `votedFor` state before returning. The bundled tuple and
  binary in-memory logs implement these callbacks, and `save_current_term/2`
  clears an earlier vote when advancing to a newer term. Equal-term writes may
  set an empty vote or repeat the existing vote, but attempts to change or
  clear an existing vote return `{:error, :already_voted}` and lower-term
  writes return `{:error, :stale_term}`.
- `Bedrock.Raft.Mode.Candidate.new/5` is now `new/6` and accepts the local peer
  identity as its first argument so the candidate's self-vote is explicit.
- AppendEntries responses now include an explicit success flag and the entry
  matched or rejected by that request. Accordingly,
  `append_entries_ack_received` mode callbacks accept five arguments, and the
  related telemetry metadata reports `success` and `request_transaction_id`.
- AppendEntries responses additionally carry the follower's newest local entry
  as an advisory hint: the wire event is now
  `{:append_entries_ack, term, success, request_transaction_id,
  follower_newest_transaction_id}`, `append_entries_ack_received` mode
  callbacks accept six arguments, and the ack telemetry metadata reports
  `follower_newest_transaction_id`.
- `Bedrock.Raft.Log` implementations must now provide
  `previous_transaction_id/2`, returning the newest transaction id older than
  the given id (or the initial id) in at most O(log n) time. The bundled
  in-memory logs implement it with `:ets.prev/2`.
- `Bedrock.Raft.Log` implementations must now provide `transactions_from/4`,
  which behaves like `transactions_from/3` but returns at most `limit`
  transactions (`:infinity` for no limit, `0` for none). The replication hot
  paths now fetch bounded batches: the leader reads exactly one batch per
  AppendEntries request and the follower reads no more existing entries than
  the request carries.

### Fixed
- Log range reads in the bundled in-memory logs are now bounded key walks over
  the ETS ordered_set (O(result + log n)) instead of match-spec selects that
  traversed the entire table regardless of the requested range. Per-operation
  replication cost no longer grows with total log history. As a side effect,
  `transactions_from` no longer raises a `CaseClauseError` when the `from` id
  is absent but later entries exist; it returns the transactions that sort
  after the given id. `purge_transactions_after` also short-circuits when
  nothing sorts after the given id, since the follower purges before every
  append and the deleting scan is only needed on an actual conflict.
- Rejected AppendEntries responses now reposition the leader's send cursor
  directly to the follower's hinted position when that entry exists in the
  leader's log, catching a lagging follower up after a single rejection
  instead of one probe round trip per missing entry. Divergent or malformed
  hints fall back to stepping one entry backwards, and the leader's
  predecessor lookup no longer materializes the entire log prefix.
- Election retries now advance the term, votes survive state reconstruction,
  and higher-term RPCs persist the new term before mode-specific handling.
- Same-term RPC responses no longer clear an existing vote, while a repeated
  RequestVote from the already-selected candidate resends the vote response.
- Rejected AppendEntries requests now backtrack an independent replication
  cursor without advancing `matchIndex`; delayed responses cannot regress
  acknowledged progress, and successful bounded batches continue immediately.
- The leader again advances each follower's replication send cursor
  optimistically as entries are sent, restoring pipelined replication. Without
  this, every appended transaction re-sent the entire unacknowledged window to
  every follower and commit goodput was capped at one bounded batch per round
  trip. The cursor remains a retry position only: acknowledged progress still
  comes exclusively from successful responses, rejections still backtrack the
  cursor, and a lost request is recovered via heartbeat probe, rejection, and
  backtrack.
- Higher-term transitions now cancel the outgoing candidate or leader timer,
  preventing an obsolete election timeout from disrupting the new leader.
- Leadership notifications now report a new term even when the identified
  leader is unchanged.

## [0.9.8] - 2026-08-30

### Changed
- Loosened the `telemetry` dependency from `~> 1.3.0` to `~> 1.3`, so `bedrock_raft`
  no longer blocks resolution in applications that depend on `telemetry` 1.4 or later.
  No code changes were needed — the library only uses the stable `:telemetry.execute/3`
  API. (Thanks to @mikehostetler.)
- The library now compiles with `warnings_as_errors` enabled, and CI runs the same
  matrix as `bedrock` (Elixir 1.17–1.20 / OTP 27–29), including `mix deps.audit`
  and Dialyzer. Development tooling is now pinned to Elixir 1.20.3 / OTP 29.
- `Bedrock.Raft.Mode.Leader.add_transaction/2` was refactored to split single-node and
  multi-node replication into separate clauses. Behaviour is unchanged.

## [0.9.7.1] - 2025-12-31

### Fixed
- Formatting corrections to `mix.exs`; no functional changes.

## [0.9.7] - 2025-12-31

### Added
- Hex package metadata (`description`, `package/0`, `docs/0`) so the library can be
  published to hex.pm, with `ex_doc` generating docs from the README and CHANGELOG.
- Build status and code coverage badges in the README, with coverage reported via
  `excoveralls`.

## [0.9.6] - 2025-08-12

### Changed
- Interface callbacks are now invoked directly (`t.interface.send_event(...)`) rather
  than through `apply/3`, improving readability and letting Dialyzer check the
  `Bedrock.Raft.Interface` calls.
- Corrected the `@spec` for `Bedrock.Raft.Mode.Candidate.new/5` to reflect that it may
  return `:become_leader` in single-node clusters.
- Added CI with Credo, Dialyzer (with cached PLTs), and test runs.

## [0.9.5] - 2025-08-03

### Changed
- Single-node clusters now start as followers and go through election process like multi-node clusters
- Candidate mode checks for immediate leadership eligibility in single-node scenarios

### Fixed
- Single-node clusters now increment terms during elections instead of remaining at term 0

## [0.9.4] - 2025-08-03

### Fixed
- **Critical Raft specification compliance**: Fixed `currentTerm` persistence across server restarts
- Added proper term storage to Log protocol with `current_term/1` and `save_current_term/2` methods
- Terms are now persisted to stable storage before responding to RPCs as required by Raft specification
- Fixed term initialization to restore from persistent storage instead of deriving from transaction IDs

### Changed
- Enhanced TupleInMemoryLog and BinaryInMemoryLog to include independent term storage
- Updated Raft initialization to comply with "persistent state" requirements from Raft paper

## [0.9.3] - 2025-08-03

### Fixed
- Leader now properly initializes `id_sequence` from existing log to prevent transaction ID conflicts
- Fixed `consensus_reached` callbacks to pass committed log instance instead of stale log reference
- Prevents leaders from attempting to create transactions with IDs that already exist in recovered logs

## [0.9.2] - 2025-08-03

### Added
- Immediate consensus for single-node clusters (quorum = 0)
- When a cluster has no peers, transactions now commit immediately without waiting for followers
- Comprehensive test coverage for single-node consensus scenarios

### Changed
- Optimized transaction processing for single-node deployments
- Single-node clusters now trigger `consensus_reached` callback immediately upon transaction addition
