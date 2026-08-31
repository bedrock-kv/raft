# Micro-benchmarks for Bedrock.Raft.Log primitives.
# Run: mix run bench/micro.exs
alias Bedrock.Raft.Log
alias Bedrock.Raft.Log.{TupleInMemoryLog, BinaryInMemoryLog}
alias Bedrock.Raft.TransactionID

defmodule Micro do
  def build_tuple_log(n) do
    log = TupleInMemoryLog.new()

    Enum.reduce(1..n, {log, {0, 0}}, fn i, {log, prev} ->
      id = {1, i}
      {:ok, log} = Log.append_transactions(log, prev, [{id, {:payload, i}}])
      {log, id}
    end)
    |> elem(0)
  end

  def build_binary_log(n) do
    log = BinaryInMemoryLog.new()

    Enum.reduce(1..n, {log, TransactionID.encode({0, 0})}, fn i, {log, prev} ->
      id = TransactionID.encode({1, i})
      {:ok, log} = Log.append_transactions(log, prev, [{id, {:payload, i}}])
      {log, id}
    end)
    |> elem(0)
  end

  def time_us(fun, reps \\ 50) do
    {us, _} = :timer.tc(fn -> Enum.each(1..reps, fn _ -> fun.() end) end)
    Float.round(us / reps, 1)
  end

  def run do
    sizes = [1_000, 10_000, 50_000, 100_000, 200_000]

    IO.puts("\n== transactions_from(log, {1, N-5}, :newest)  [5-entry suffix] ==")
    IO.puts("N        tuple_us    binary_us")

    for n <- sizes do
      tl = build_tuple_log(n)
      bl = build_binary_log(n)
      t = time_us(fn -> Log.transactions_from(tl, {1, n - 5}, :newest) end)
      b = time_us(fn -> Log.transactions_from(bl, TransactionID.encode({1, n - 5}), :newest) end)
      IO.puts(String.pad_trailing("#{n}", 9) <> String.pad_trailing("#{t}", 12) <> "#{b}")
      :ets.delete(tl.transactions)
      :ets.delete(bl.transactions)
    end

    IO.puts("\n== transactions_from/4 (limit 10, from mid-log) ==")
    IO.puts("N        tuple_us    binary_us")

    for n <- sizes do
      tl = build_tuple_log(n)
      bl = build_binary_log(n)
      t = time_us(fn -> Log.transactions_from(tl, {1, div(n, 2)}, :newest, 10) end)

      b =
        time_us(fn ->
          Log.transactions_from(bl, TransactionID.encode({1, div(n, 2)}), :newest, 10)
        end)

      IO.puts(String.pad_trailing("#{n}", 9) <> String.pad_trailing("#{t}", 12) <> "#{b}")
      :ets.delete(tl.transactions)
      :ets.delete(bl.transactions)
    end

    IO.puts("\n== control: :ets.next-based walk of same 5-entry suffix (tuple log) ==")
    IO.puts("N        next_walk_us")

    for n <- sizes do
      tl = build_tuple_log(n)

      t =
        time_us(fn ->
          Stream.unfold({1, n - 5}, fn k ->
            case :ets.next(tl.transactions, k) do
              :"$end_of_table" -> nil
              k2 -> {hd(:ets.lookup(tl.transactions, k2)), k2}
            end
          end)
          |> Enum.to_list()
        end)

      IO.puts(String.pad_trailing("#{n}", 9) <> "#{t}")
      :ets.delete(tl.transactions)
    end

    IO.puts("\n== has_transaction_id? (tuple, mid-log key) ==")

    for n <- [10_000, 200_000] do
      tl = build_tuple_log(n)
      t = time_us(fn -> Log.has_transaction_id?(tl, {1, div(n, 2)}) end, 1000)
      IO.puts("N=#{n}  #{t} us")
      :ets.delete(tl.transactions)
    end

    IO.puts("\n== leader-side cost per REJECTION ack (hint jump to empty-follower position) ==")
    IO.puts("N        us_per_rejection")

    for n <- [1_000, 5_000, 10_000, 20_000, 40_000] do
      tl = build_tuple_log(n)
      leader = Bedrock.Raft.Mode.Leader.new(1, 1, [:b, :c], tl, Micro.Iface)

      t =
        time_us(
          fn ->
            {:ok, _} =
              Bedrock.Raft.Mode.Leader.append_entries_ack_received(leader, 1, false, {1, n}, {0, 0}, :b)

            flush()
          end,
          20
        )

      IO.puts(String.pad_trailing("#{n}", 9) <> "#{t}")
      :ets.delete(tl.transactions)
    end

    IO.puts("\n== leader-side cost per REJECTION ack (fallback: hint not in our log) ==")
    IO.puts("N        us_per_rejection")

    for n <- [1_000, 5_000, 10_000, 20_000, 40_000] do
      tl = build_tuple_log(n)
      leader = Bedrock.Raft.Mode.Leader.new(1, 1, [:b, :c], tl, Micro.Iface)

      t =
        time_us(
          fn ->
            {:ok, _} =
              Bedrock.Raft.Mode.Leader.append_entries_ack_received(
                leader,
                1,
                false,
                {1, n},
                {9, 9},
                :b
              )

            flush()
          end,
          20
        )

      IO.puts(String.pad_trailing("#{n}", 9) <> "#{t}")
      :ets.delete(tl.transactions)
    end

    IO.puts("\n== Log.previous_transaction_id (tuple, near-end key) ==")

    for n <- [10_000, 200_000] do
      tl = build_tuple_log(n)
      t = time_us(fn -> Log.previous_transaction_id(tl, {1, n - 3}) end, 1000)
      IO.puts("N=#{n}  #{t} us")
      :ets.delete(tl.transactions)
    end

    IO.puts("\n== leader-side cost per SUCCESS ack at head of log (steady state) ==")
    IO.puts("N        us_per_success_ack")

    for n <- [1_000, 5_000, 10_000, 20_000, 40_000] do
      tl = build_tuple_log(n)
      # leader whose followers have fully caught up; ack newest again (duplicate)
      leader = Bedrock.Raft.Mode.Leader.new(1, 1, [:b, :c], tl, Micro.Iface)

      {:ok, leader} =
        Bedrock.Raft.Mode.Leader.append_entries_ack_received(leader, 1, true, {1, n}, {1, n}, :b)

      flush()

      t =
        time_us(
          fn ->
            {:ok, _} =
              Bedrock.Raft.Mode.Leader.append_entries_ack_received(leader, 1, true, {1, n}, {1, n}, :b)

            flush()
          end,
          50
        )

      IO.puts(String.pad_trailing("#{n}", 9) <> "#{t}")
      :ets.delete(tl.transactions)
    end
  end

  def flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

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
end

Micro.run()
