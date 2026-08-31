# Replication performance benchmarks

Development-only harnesses used to measure the Raft replication paths. They
are not part of the library and are not compiled into releases.

## bench/sim.exs

An in-process three-node cluster simulator (`:a`, `:b`, `:c`) that drives the
real `Bedrock.Raft` state machines and counts every message and entry payload
on the wire.

    mix run bench/sim.exs e1    # message amplification: lockstep vs. stalled burst
    mix run bench/sim.exs e2    # commit goodput under simulated network delay
    mix run bench/sim.exs e3a   # forward catch-up of a partitioned follower
    mix run bench/sim.exs e3b   # backtracking catch-up after a leadership change
    mix run bench/sim.exs e4    # cost per add as log history grows

## bench/micro.exs

Micro-benchmarks for the `Bedrock.Raft.Log` primitives (range reads, membership
checks, and leader-side handling of success/rejection responses) across log
sizes.

    mix run bench/micro.exs
