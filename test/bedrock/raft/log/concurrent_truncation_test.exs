defmodule Bedrock.Raft.Log.ConcurrentTruncationTest do
  use ExUnit.Case, async: true

  alias Bedrock.Raft.Log
  alias Bedrock.Raft.Log.BinaryInMemoryLog
  alias Bedrock.Raft.Log.TupleInMemoryLog
  alias Bedrock.Raft.TransactionID

  @entries 20_000
  @purge_at 19_500
  @read_from 19_000
  @owner_cycles 100
  @reader_loops 400
  @readers 10

  # The ETS tables are protected: the owner writes, any process may read.
  # A reader walking the log while the owner truncates a conflicting suffix
  # (purge_transactions_after + re-append) must never crash; it may observe
  # a shortened result. Asserts only on the absence of crashes -- result
  # contents under a concurrent truncation are intentionally unspecified.
  defp stress(log, id_fun) do
    initial_id = Log.initial_transaction_id(log)
    {:ok, log} = Log.append_transactions(log, initial_id, transactions(id_fun, 1, @entries))

    read_from = id_fun.(@read_from)

    readers =
      for _ <- 1..@readers do
        Task.async(fn -> read_repeatedly(log, read_from) end)
      end

    purge_at = id_fun.(@purge_at)
    tail = transactions(id_fun, @purge_at + 1, @entries)

    for _ <- 1..@owner_cycles do
      {:ok, _} = Log.purge_transactions_after(log, purge_at)
      {:ok, _} = Log.append_transactions(log, purge_at, tail)
    end

    assert Enum.all?(readers, fn task -> Task.await(task, 30_000) == :ok end)
  end

  defp read_repeatedly(log, read_from) do
    for _ <- 1..@reader_loops do
      Log.transactions_from(log, read_from, :newest)
    end

    :ok
  end

  defp transactions(id_fun, from, to),
    do: for(i <- from..to, do: {id_fun.(i), {:data, i}})

  test "tuple log readers survive concurrent truncation" do
    stress(TupleInMemoryLog.new(), &TransactionID.new(1, &1))
  end

  test "binary log readers survive concurrent truncation" do
    stress(BinaryInMemoryLog.new(), &TransactionID.encode({1, &1}))
  end
end
