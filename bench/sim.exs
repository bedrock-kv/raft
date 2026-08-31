# In-process 3-node cluster simulator for replication performance experiments.
# Run: mix run bench/sim.exs <e1|e2|e3a|e3b|e4>
alias Bedrock.Raft
alias Bedrock.Raft.Log
alias Bedrock.Raft.Log.InMemoryLog

defmodule Sim do
  defmodule Iface do
    def timer(_), do: fn -> :ok end
    def send_event(to, ev), do: (send(self(), {:out, to, ev}); :ok)
    def leadership_changed(_), do: :ok
    def consensus_reached(_, _, _), do: :ok
    def timestamp_in_ms, do: Process.get(:sim_clock, 1000)
    def heartbeat_ms, do: 50
    def quorum_lost(_, _, _), do: :continue
    def ignored_event(_, _), do: :ok
  end

  def clock_advance(ms), do: Process.put(:sim_clock, Process.get(:sim_clock, 1000) + ms)

  def new_cluster(names \\ [:a, :b, :c]) do
    Map.new(names, fn n -> {n, Raft.new(n, names -- [n], InMemoryLog.new(), Iface)} end)
  end

  def drain(from, acc \\ []) do
    receive do
      {:out, to, ev} -> drain(from, [{to, from, ev} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def handle(cluster, node, event, from) do
    raft = Raft.handle_event(cluster[node], event, from)
    {Map.put(cluster, node, raft), drain(node)}
  end

  def add(cluster, node, payload) do
    {:ok, raft, _id} = Raft.add_transaction(cluster[node], payload)
    {Map.put(cluster, node, raft), drain(node)}
  end

  def zero,
    do: %{msgs: 0, ae: 0, ae_entries: 0, ack_ok: 0, ack_fail: 0, other: 0, ae_to: 0, entries_to: 0}

  defp classify({:append_entries, _t, _p, txns, _c}), do: {:ae, length(txns)}

  defp classify({:append_entries_ack, _t, s, _r}) when is_boolean(s),
    do: if(s, do: :ack_ok, else: :ack_fail)

  defp classify(_), do: :other

  defp count(stats, to, ev, track_to) do
    stats = %{stats | msgs: stats.msgs + 1}

    stats =
      case classify(ev) do
        {:ae, n} ->
          s = %{stats | ae: stats.ae + 1, ae_entries: stats.ae_entries + n}

          if to == track_to,
            do: %{s | ae_to: s.ae_to + 1, entries_to: s.entries_to + n},
            else: s

        k ->
          Map.update!(stats, k, &(&1 + 1))
      end

    stats
  end

  def pump(cluster, msgs, opts \\ []) do
    drop = opts[:drop] || fn _ -> false end
    track_to = opts[:track_to]
    do_pump(cluster, :queue.from_list(msgs), drop, track_to, zero(), 0)
  end

  defp do_pump(_c, _q, _d, _t, _s, n) when n > 3_000_000, do: raise("pump did not quiesce")

  defp do_pump(cluster, q, drop, track_to, stats, n) do
    case :queue.out(q) do
      {:empty, _} ->
        {cluster, stats}

      {{:value, {to, from, ev} = m}, q} ->
        if drop.(m) do
          do_pump(cluster, q, drop, track_to, stats, n)
        else
          stats = count(stats, to, ev, track_to)
          {cluster, outs} = handle(cluster, to, ev, from)
          do_pump(cluster, :queue.join(q, :queue.from_list(outs)), drop, track_to, stats, n + 1)
        end
    end
  end

  def merge(a, b), do: Map.new(a, fn {k, v} -> {k, v + b[k]} end)

  def committed(cluster, node) do
    case Log.newest_safe_transaction_id(Raft.log(cluster[node])) do
      {_, i} -> i
      _ -> 0
    end
  end

  def elect(leader \\ :a) do
    cluster = new_cluster()
    {cluster, outs} = handle(cluster, leader, :election, :timer)
    {cluster, _} = pump(cluster, outs)
    cluster
  end

  # E1: message amplification. Lockstep (pump after each add) vs burst
  # (network stalled during N adds, then delivered).
  def e1(n) do
    cluster = elect()

    {_, lock} =
      Enum.reduce(1..n, {cluster, zero()}, fn i, {c, s} ->
        {c, outs} = add(c, :a, {:tx, i})
        {c, s2} = pump(c, outs)
        {c, merge(s, s2)}
      end)

    IO.puts("E1 lockstep  N=#{n}: #{fmt(lock)}  (per add: #{Float.round(lock.msgs / n, 1)} msgs, #{Float.round(lock.ae_entries / n, 2)} entry payloads)")

    cluster = elect()

    {cluster, pend} =
      Enum.reduce(1..n, {cluster, []}, fn i, {c, acc} ->
        {c, outs} = add(c, :a, {:tx, i})
        {c, acc ++ outs}
      end)

    {us, {cluster, burst}} = :timer.tc(fn -> pump(cluster, pend) end)

    IO.puts("E1 burst     N=#{n}: #{fmt(burst)}  committed=#{committed(cluster, :a)}  pump=#{div(us, 1000)}ms")
    IO.puts("E1 burst amplification: #{Float.round(burst.ae_entries / n, 1)}x entry payloads per committed entry")
  end

  # E2: goodput under network delay d (in rounds), one add per round.
  def e2(rounds, d, n_adds) do
    cluster = elect()

    schedule = fn sched, r, msgs -> Map.update(sched, r, msgs, &(&1 ++ msgs)) end

    {cluster, sched, stats, _} =
      Enum.reduce(1..rounds, {cluster, %{}, zero(), schedule}, fn r, {c, sched, stats, schedule} ->
        {c, stats} =
          Enum.reduce(Map.get(sched, r, []), {c, stats}, fn {to, from, ev}, {c, stats} ->
            stats = count(stats, to, ev, nil)
            {c, outs} = handle(c, to, ev, from)
            Process.put({:due, r}, (Process.get({:due, r}) || []) ++ outs)
            {c, stats}
          end)

        sched = schedule.(sched, r + d, Process.get({:due, r}) || [])
        Process.delete({:due, r})

        {c, sched} =
          if r <= n_adds do
            {c, outs} = add(c, :a, {:tx, r})
            {c, schedule.(sched, r + d, outs)}
          else
            {c, sched}
          end

        {c, sched, stats, schedule}
      end)

    _ = sched

    IO.puts("E2 delay=#{d} rounds, #{n_adds} adds over #{rounds} rounds: committed=#{committed(cluster, :a)}  #{fmt(stats)}")
    IO.puts("E2 goodput=#{Float.round(committed(cluster, :a) / rounds, 3)} entries/round (add rate 1.0); amplification=#{Float.round(stats.ae_entries / max(committed(cluster, :a), 1), 1)}x")
  end

  # Build: :a leader, :c partitioned during n adds (lockstep with :b).
  def build_partitioned(n) do
    drop_c = fn {to, from, _} -> to == :c or from == :c end
    cluster = elect()

    Enum.reduce(1..n, cluster, fn i, c ->
      {c, outs} = add(c, :a, {:tx, i})
      {c, _} = pump(c, outs, drop: drop_c)
      c
    end)
  end

  # E3a: heal and catch :c up via heartbeat (leader cursor for :c is at 0 -> forward-only).
  def e3a(n) do
    cluster = build_partitioned(n)
    clock_advance(1000)
    {cluster, outs} = handle(cluster, :a, :heartbeat, :timer)
    {us, {cluster, stats}} = :timer.tc(fn -> pump(cluster, outs, track_to: :c) end)

    IO.puts("E3a forward catch-up N=#{n}: AE_to_c=#{stats.ae_to} entries_to_c=#{stats.entries_to} time=#{div(us, 1000)}ms committed_c=#{committed(cluster, :c)}")
  end

  # E3b: re-elect :b (fresh cursor = newest), then heal :c -> full backtrack.
  def e3b(n) do
    cluster = build_partitioned(n)
    clock_advance(1000)
    {cluster, outs} = handle(cluster, :b, :election, :timer)
    {cluster, _} = pump(cluster, outs)

    if not Raft.am_i_the_leader?(cluster[:b]), do: raise("b not leader")

    clock_advance(1000)
    {cluster, outs} = handle(cluster, :b, :heartbeat, :timer)
    {us, {cluster, stats}} = :timer.tc(fn -> pump(cluster, outs, track_to: :c) end)

    IO.puts("E3b backtrack catch-up N=#{n}: AE_to_c=#{stats.ae_to} entries_to_c=#{stats.entries_to} acks_fail=#{stats.ack_fail} time=#{div(us, 1000)}ms committed_c=#{committed(cluster, :c)}")
  end

  # E4: lockstep add+pump forever; time each batch as history grows.
  def e4(batch, n_batches) do
    cluster = elect()

    Enum.reduce(1..n_batches, cluster, fn b, c ->
      {us, c} =
        :timer.tc(fn ->
          Enum.reduce(1..batch, c, fn i, c ->
            {c, outs} = add(c, :a, {:tx, b, i})
            {c, _} = pump(c, outs)
            c
          end)
        end)

      total = (b * batch) |> Integer.to_string() |> String.pad_trailing(8)
      IO.puts("E4 log_size=#{total} batch_of_#{batch}=#{div(us, 1000)}ms  (#{Float.round(us / batch, 1)} us/add)")
      c
    end)
  end

  defp fmt(s),
    do: "msgs=#{s.msgs} ae=#{s.ae} ae_entries=#{s.ae_entries} ack_ok=#{s.ack_ok} ack_fail=#{s.ack_fail}"
end

case System.argv() do
  ["e1"] -> Sim.e1(100)
  ["e2"] -> for d <- [2, 5, 10, 20], do: Sim.e2(2000, d, 1000)
  ["e3a"] -> for n <- [200, 400, 800, 1600], do: Sim.e3a(n)
  ["e3b"] -> for n <- [100, 200, 400, 800, 1600], do: Sim.e3b(n)
  ["e4"] -> Sim.e4(1000, 6)
  _ -> IO.puts("usage: mix run bench/sim.exs <e1|e2|e3a|e3b|e4>")
end
