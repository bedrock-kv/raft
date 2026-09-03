# Bedrock Raft

[![Build Status](https://github.com/bedrock-kv/raft/actions/workflows/elixir_ci.yaml/badge.svg)](https://github.com/bedrock-kv/raft/actions/workflows/elixir_ci.yaml?branch=main)
[![Coverage Status](https://coveralls.io/repos/github/bedrock-kv/raft/badge.svg?branch=main)](https://coveralls.io/github/bedrock-kv/raft?branch=main)

An implementation of the [Raft consensus algorithm](https://raft.github.io/) in
Elixir, built as a state machine you embed in your own application rather than a
service you run.

Raft lets a cluster of machines agree on an ordered log of entries even as
individual machines crash, restart, or fall out of contact — the foundation you
need to build something like a replicated database or a distributed lock. This
library gives you the *decision-making* part of Raft. It decides who the leader
is, which entries are safe to commit, and what message each peer should send
next. It deliberately does **not** decide how those messages travel, how timers
fire, or where the log is stored. You provide those, which means the same
protocol code runs unchanged inside a GenServer, across real nodes, or in a
fast in-memory test.

If you already know Raft, skip to [How it works](#how-it-works). If you don't,
the next section is a two-minute orientation.

## A quick mental model of Raft

A Raft cluster keeps several copies of the same growing log in sync. At any
moment each peer is in one of three roles:

- **Follower** — the resting state. Followers are passive: they wait to hear
  from a leader and answer its requests.
- **Candidate** — a follower that stopped hearing from a leader, so it stood up
  and asked everyone to vote for it.
- **Leader** — the candidate that won a majority of votes. The leader is the
  only peer that accepts new entries, and it replicates them to the followers.

Time is divided into numbered **terms**, which act as a logical clock: every
election starts a new term, and a higher term always wins, so stale leaders
step down as soon as they see one.

An entry is **committed** — safe, durable, never to be lost — once a majority of
peers have stored it. That majority is the whole point: as long as more than
half the cluster is alive and talking, progress continues and committed data
survives any minority failing.

That's enough to read the rest of this page. For the real thing, see the
[Raft paper site](https://raft.github.io/), the visual walkthrough at
[The Secret Lives of Data](http://thesecretlivesofdata.com/raft/), or
[this concise write-up](https://arorashu.github.io/posts/raft.html).

## What this library does, and what it leaves to you

**It handles the whole protocol:**

- Leader election, including split votes, retries, and term advancement.
- Log replication: bringing lagging followers up to date, and the consistency
  checks that keep every peer's log identical.
- The subtle safety rules that make Raft correct — committing only current-term
  entries by counting replicas (§5.4.2), truncating a follower's log only at a
  genuine conflict (§5.3), and persisting term and vote before acting on any
  request.
- Pipelined replication with per-follower progress tracking, so a busy leader
  keeps entries flowing instead of stalling for a round trip per entry.
- A [telemetry](https://hexdocs.pm/telemetry/) event for every meaningful
  transition, so you can observe elections, replication, and commits.

**It leaves the moving parts to you**, through two behaviours you implement:

| You provide            | So that the protocol can…                          |
| ---------------------- | -------------------------------------------------- |
| An **`Interface`**     | set timers, send messages to peers, and tell your app when leadership changes or an entry commits |
| A **`Log`**            | store, read, and truncate log entries, and remember the current term and vote |

Nothing in this library opens a socket, spawns a process, or writes to disk.
That is the design, not an omission: by keeping every side effect behind those
two seams, the exact same protocol code is testable in memory and portable to
whatever runtime and transport you already have.

The library ships with in-memory logs (`Bedrock.Raft.Log.InMemoryLog`) that are
perfect for tests and for learning, but make **no durability guarantees**. A
production deployment supplies its own `Log` backed by stable storage.

## How it works

You hold a `Bedrock.Raft` struct and drive it by handing it events — a timer
firing, or a message from another peer — with `handle_event/3`. Each call
returns a new struct; you keep the returned value and use it for the next call.
As the protocol works, it calls *out* through your `Interface` to send messages,
set timers, and report results.

The two seams:

**`Bedrock.Raft.Interface`** — the protocol's outbound edge. You implement, among
others:

- `timer/1` — start an election or heartbeat timer; return a function that
  cancels it. When the timer fires, you feed it back in as an event.
- `send_event/2` — deliver a message to another peer, however you like (Erlang
  message passing, TCP, a test mailbox).
- `leadership_changed/1` — the leader or term changed.
- `consensus_reached/3` — entries up to a given point are now committed. This is
  where your application acts on agreed-upon data.

**`Bedrock.Raft.Log`** — the protocol's storage edge: append and read ranges of
entries, check whether an entry exists, mark entries committed, and hold the
persistent term and vote. Bring your own for durability, or use a bundled
in-memory one to start.

Entries are identified by a **transaction ID**, a `{term, index}` pair that
sorts in log order. The library can also encode it as an order-preserving
binary, so log implementations backed by a byte-keyed store stay correctly
ordered with plain comparisons.

## A minimal, runnable example

The smallest interesting cluster has one node. With no peers, a majority is just
itself, so a new entry commits immediately — no networking required. That makes
a single node the clearest way to see the pieces fit together and actually run
the protocol end to end.

```elixir
defmodule Demo.Interface do
  @behaviour Bedrock.Raft.Interface

  # A one-node cluster never needs to talk to anyone, so transport and timers
  # can be stubs here. A real cluster wires these to your messaging and timers.
  @impl true
  def send_event(_peer, _event), do: :ok

  @impl true
  def timer(_kind), do: fn -> :ok end

  @impl true
  def heartbeat_ms, do: 50

  @impl true
  def timestamp_in_ms, do: System.monotonic_time(:millisecond)

  @impl true
  def leadership_changed({leader, term}) do
    IO.puts("leadership: #{inspect(leader)} in term #{term}")
    :ok
  end

  @impl true
  def consensus_reached(_log, txn_id, _freshness) do
    IO.puts("committed up to #{inspect(txn_id)}")
    :ok
  end

  @impl true
  def ignored_event(_event, _from), do: :ok

  @impl true
  def quorum_lost(_active, _total, _term), do: :continue
end

alias Bedrock.Raft
alias Bedrock.Raft.Log.InMemoryLog

# Create a node named :node1 with no peers and an in-memory log.
raft = Raft.new(:node1, [], InMemoryLog.new(), Demo.Interface)

# Nodes start as followers. With no one to wait for, an election timeout makes
# this node a candidate and then, unopposed, the leader.
raft = Raft.handle_event(raft, :election, :timer)
true = Raft.am_i_the_leader?(raft)

# Only a leader accepts entries. Add one; on a single node it commits at once,
# and `consensus_reached/3` fires.
{:ok, _raft, _txn_id} = Raft.add_transaction(raft, %{set: {"key", "value"}})
```

Running it prints the leadership change, then the commit.

Growing to a real cluster changes none of the protocol calls above — you pass
the peer list to `new/5`, and you flesh out `send_event/2` and `timer/1` so
peers actually exchange messages and elections actually time out. The events you
receive from other peers get handed to the same `handle_event/3`. The protocol
does the rest: elects a leader, replicates entries, and calls
`consensus_reached/3` once a majority has each one.

## Installation

```elixir
def deps do
  [
    {:bedrock_raft, "~> 0.10"}
  ]
end
```

## Testing and correctness

Consensus code is exactly the kind of code where "it passes the tests" and "it
is correct" can quietly diverge: the dangerous bugs hide in specific orderings
of delayed, dropped, and reordered messages that a naive test never produces. So
the suite is written to probe *behaviour under adversity*, not just to touch
every line.

- Dedicated tests for the protocol's safety properties (`election_safety_test`)
  and for the concurrency hazard of reading a log while it is truncated
  (`concurrent_truncation_test`).
- Thorough per-component tests for each mode (follower, candidate, leader),
  follower progress tracking, and both log encodings — roughly 1.6 lines of
  test for every line of library code.
- An in-process multi-node simulator under [`bench/`](bench/) that drives the
  real state machines and counts every message and entry on the wire, used to
  check replication behaviour and catch regressions in message volume.

Line coverage sits above 90%, but treat that as a floor rather than the
headline: the behavioural and simulation tests above are what give confidence
that the protocol is correct, not the percentage.

## Documentation

- Generated API docs are published on [HexDocs](https://hexdocs.pm/bedrock_raft).
- The [CHANGELOG](CHANGELOG.md) records the protocol's evolution in detail,
  including the specific safety fixes behind recent releases.

## License

MIT — see [LICENSE](LICENSE).
