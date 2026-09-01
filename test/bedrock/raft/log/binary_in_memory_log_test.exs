defmodule Bedrock.Raft.Log.BinaryInMemoryLogTest do
  use ExUnit.Case, async: true
  alias Bedrock.Raft.Log
  alias Bedrock.Raft.Log.BinaryInMemoryLog
  alias Bedrock.Raft.TransactionID

  setup do
    log = BinaryInMemoryLog.new()

    {:ok, log: log}
  end

  describe "new/0" do
    test "creates a new binary in-memory log", %{log: log} do
      assert log.transactions != nil
    end
  end

  describe "persistent election state" do
    test "stores term and vote atomically and clears the vote in a newer term", %{log: log} do
      assert Log.current_term(log) == 0
      assert Log.voted_for(log) == nil

      {:ok, log} = Log.save_election_state(log, 3, :candidate_a)
      assert Log.current_term(log) == 3
      assert Log.voted_for(log) == :candidate_a

      {:ok, log} = Log.save_current_term(log, 4)
      assert Log.current_term(log) == 4
      assert Log.voted_for(log) == nil
    end

    test "rejects changing or clearing a vote in the same term", %{log: log} do
      {:ok, log} = Log.save_election_state(log, 3, :candidate_a)

      assert {:error, :already_voted} = Log.save_election_state(log, 3, :candidate_b)
      assert {:error, :already_voted} = Log.save_election_state(log, 3, nil)
      assert Log.current_term(log) == 3
      assert Log.voted_for(log) == :candidate_a
    end

    test "rejects election state from an older term", %{log: log} do
      {:ok, log} = Log.save_election_state(log, 3, :candidate_a)

      assert {:error, :stale_term} = Log.save_election_state(log, 2, :candidate_b)
      assert Log.current_term(log) == 3
      assert Log.voted_for(log) == :candidate_a
    end
  end

  describe "new_id/1" do
    test "returns the initial transaction ID", %{log: log} do
      assert Log.new_id(log, 0, 0) == TransactionID.encode({0, 0})
    end

    test "returns a new transaction ID", %{log: log} do
      assert Log.new_id(log, 0, 1) == TransactionID.encode({0, 1})
    end
  end

  describe "append_transactions/3" do
    test "appends transactions to the log when the log is empty", %{log: log} do
      transaction_id_0 = TransactionID.encode({0, 0})

      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}
      {:ok, updated_log} = Log.append_transactions(log, transaction_id_0, [transaction])

      assert :ets.lookup(updated_log.transactions, transaction_id) == [transaction]
    end

    test "appends transactions to the log when the log has entries", %{log: log} do
      transaction_id_0 = TransactionID.encode({0, 0})

      transaction_1_id = TransactionID.encode({0, 1})
      transaction_1 = {transaction_1_id, :some_data}
      {:ok, log} = Log.append_transactions(log, transaction_id_0, [transaction_1])

      transaction_2_id = TransactionID.encode({0, 2})
      transaction_2 = {transaction_2_id, :some_more_data}
      {:ok, log} = Log.append_transactions(log, transaction_1_id, [transaction_2])

      assert Log.transactions_from(log, transaction_1_id, :newest) == [
               transaction_2
             ]

      assert Log.transactions_from(log, transaction_2_id, :newest) == []
    end

    test "returns an error when the previous transaction is not found", %{log: log} do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      assert {:error, :prev_transaction_not_found} ==
               Log.append_transactions(log, TransactionID.encode({5, 5}), [
                 transaction
               ])
    end
  end

  describe "commit_up_to/2" do
    test "commits transactions up to the given transaction ID", %{log: log} do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      {:ok, updated_log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])

      {:ok, committed_log} = Log.commit_up_to(updated_log, transaction_id)

      assert committed_log.last_commit == transaction_id
    end
  end

  describe "initial_transaction_id/1" do
    test "returns the initial transaction ID", %{log: log} do
      assert Log.initial_transaction_id(log) == TransactionID.encode({0, 0})
    end
  end

  describe "newest_transaction_id/1" do
    test "returns nil when there are no transactions", %{log: log} do
      assert Log.newest_transaction_id(log) == TransactionID.encode({0, 0})
    end

    test "returns the newest transaction ID", %{log: log} do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      {:ok, updated_log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])

      assert Log.newest_transaction_id(updated_log) == transaction_id
    end
  end

  describe "newest_safe_transaction_id/1" do
    test "returns the initial transaction ID when there are no transactions", %{log: log} do
      assert Log.newest_safe_transaction_id(log) == TransactionID.encode({0, 0})
    end

    test "returns the last committed transaction ID", %{log: log} do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      {:ok, updated_log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])

      {:ok, committed_log} = Log.commit_up_to(updated_log, transaction_id)

      assert Log.newest_safe_transaction_id(committed_log) == transaction_id
    end
  end

  describe "has_transaction_id?/2" do
    test "returns true when the transaction ID is the initial transaction ID", %{log: log} do
      assert Log.has_transaction_id?(log, TransactionID.encode({0, 0}))
    end

    test "returns false when the transaction ID is not in the log", %{log: log} do
      assert !Log.has_transaction_id?(log, TransactionID.encode({0, 1}))
    end

    test "returns true when the transaction ID is in the log", %{log: log} do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      {:ok, updated_log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])

      assert Log.has_transaction_id?(updated_log, transaction_id)
    end
  end

  describe "transactions_to/2" do
    test "returns all transactions up to the newest transaction ID", %{log: log} do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      {:ok, updated_log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])

      assert Log.transactions_to(updated_log, :newest) == [transaction]
    end

    test "returns all transactions up to the newest safe transaction ID", %{log: log} do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      {:ok, updated_log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])

      {:ok, committed_log} = Log.commit_up_to(updated_log, transaction_id)

      assert Log.transactions_to(committed_log, :newest_safe) == [transaction]
    end
  end

  describe "transactions_from/3" do
    test "returns all transactions from the given transaction ID to the newest transaction ID", %{
      log: log
    } do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      {:ok, updated_log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])

      assert Log.transactions_from(updated_log, TransactionID.encode({0, 0}), :newest) == [
               transaction
             ]
    end

    test "returns all transactions from the given transaction ID to the newest safe transaction ID",
         %{log: log} do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      {:ok, updated_log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])

      {:ok, committed_log} = Log.commit_up_to(updated_log, transaction_id)

      assert Log.transactions_from(committed_log, TransactionID.encode({0, 0}), :newest_safe) == [
               transaction
             ]
    end

    test "returns empty list when from transaction is not found", %{log: log} do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      {:ok, updated_log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])

      assert Log.transactions_from(updated_log, TransactionID.encode({1, 0}), :newest) == []
    end
  end

  describe "purge_transactions_after/2" do
    test "purges uncommitted transactions after the given transaction ID", %{log: log} do
      transaction_1_id = TransactionID.encode({0, 1})
      transaction_1 = {transaction_1_id, :data_1}
      transaction_2_id = TransactionID.encode({0, 2})
      transaction_2 = {transaction_2_id, :data_2}

      {:ok, log} = Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction_1])
      {:ok, log} = Log.append_transactions(log, transaction_1_id, [transaction_2])
      {:ok, log} = Log.commit_up_to(log, transaction_1_id)

      {:ok, purged_log} = Log.purge_transactions_after(log, transaction_1_id)

      assert !Log.has_transaction_id?(purged_log, transaction_2_id)
      assert Log.has_transaction_id?(purged_log, transaction_1_id)
      assert purged_log.last_commit == transaction_1_id
    end

    test "rejects a purge that would delete committed transactions", %{log: log} do
      transaction_1_id = TransactionID.encode({0, 1})
      transaction_2_id = TransactionID.encode({0, 2})

      transactions = [
        {transaction_1_id, :data_1},
        {transaction_2_id, :data_2}
      ]

      {:ok, log} = Log.append_transactions(log, TransactionID.encode({0, 0}), transactions)
      {:ok, log} = Log.commit_up_to(log, transaction_2_id)

      assert {:error, :would_delete_committed_transactions} =
               Log.purge_transactions_after(log, transaction_1_id)

      assert Log.transactions_to(log, :newest) == transactions
      assert Log.newest_safe_transaction_id(log) == transaction_2_id
    end
  end

  describe "commit_up_to/2 edge cases" do
    test "returns :unchanged when committing to initial transaction ID", %{log: log} do
      assert Log.commit_up_to(log, TransactionID.encode({0, 0})) == :unchanged
    end

    test "returns :unchanged when transaction ID is not newer than last commit", %{log: log} do
      transaction_id = TransactionID.encode({0, 1})
      transaction = {transaction_id, :some_data}

      {:ok, log} = Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])
      {:ok, committed_log} = Log.commit_up_to(log, transaction_id)

      assert Log.commit_up_to(committed_log, transaction_id) == :unchanged
    end
  end

  describe "append_transactions/3 with tuple transaction IDs" do
    test "accepts transactions with tuple transaction IDs", %{log: log} do
      transaction = {{0, 1}, :some_data}

      {:ok, updated_log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])

      expected_id = TransactionID.encode({0, 1})
      assert Log.has_transaction_id?(updated_log, expected_id)
      assert Log.transactions_to(updated_log, :newest) == [{expected_id, :some_data}]
    end
  end

  describe "previous_transaction_id/2" do
    test "returns the preceding transaction ID and handles the edges", %{log: log} do
      initial_id = Log.initial_transaction_id(log)

      {:ok, log} =
        Log.append_transactions(log, initial_id, [
          {TransactionID.encode({1, 1}), :data_1},
          {TransactionID.encode({1, 2}), :data_2}
        ])

      assert Log.previous_transaction_id(log, TransactionID.encode({1, 2})) ==
               TransactionID.encode({1, 1})

      assert Log.previous_transaction_id(log, TransactionID.encode({1, 1})) == initial_id
      assert Log.previous_transaction_id(log, initial_id) == initial_id

      assert Log.previous_transaction_id(log, TransactionID.encode({9, 9})) ==
               TransactionID.encode({1, 2})
    end
  end

  describe "transactions_from/3 bounded-walk semantics" do
    setup %{log: log} do
      ids = for i <- 1..6, do: TransactionID.encode({1, i})
      transactions = Enum.map(ids, &{&1, {:data, &1}})
      {:ok, log} = Log.append_transactions(log, TransactionID.encode({0, 0}), transactions)
      {:ok, log: log, transactions: transactions}
    end

    test "returns a middle range, exclusive of from and inclusive of to", %{
      log: log,
      transactions: transactions
    } do
      assert Log.transactions_from(
               log,
               TransactionID.encode({1, 2}),
               TransactionID.encode({1, 5})
             ) ==
               Enum.slice(transactions, 2, 3)
    end

    test "returns everything after the initial ID", %{log: log, transactions: transactions} do
      assert Log.transactions_from(log, TransactionID.encode({0, 0}), :newest) == transactions
    end

    test "a to beyond the newest entry stops at the newest entry", %{
      log: log,
      transactions: transactions
    } do
      assert Log.transactions_from(
               log,
               TransactionID.encode({1, 2}),
               TransactionID.encode({9, 9})
             ) ==
               Enum.slice(transactions, 2, 4)
    end

    test "an empty log returns an empty list" do
      log = BinaryInMemoryLog.new()
      assert Log.transactions_from(log, TransactionID.encode({0, 0}), :newest) == []
    end

    test "a single-entry log returns its entry" do
      log = BinaryInMemoryLog.new()
      transaction = {TransactionID.encode({1, 1}), :only}
      {:ok, log} = Log.append_transactions(log, TransactionID.encode({0, 0}), [transaction])
      assert Log.transactions_from(log, TransactionID.encode({0, 0}), :newest) == [transaction]
      assert Log.transactions_from(log, TransactionID.encode({1, 1}), :newest) == []
    end

    test "an absent from returns the transactions that sort after it" do
      log = BinaryInMemoryLog.new()

      {:ok, log} =
        Log.append_transactions(log, TransactionID.encode({0, 0}), [
          {TransactionID.encode({1, 1}), :a},
          {TransactionID.encode({1, 2}), :b},
          {TransactionID.encode({1, 4}), :c}
        ])

      assert Log.transactions_from(log, TransactionID.encode({1, 3}), :newest) == [
               {TransactionID.encode({1, 4}), :c}
             ]
    end
  end

  describe "transactions_from/4" do
    setup %{log: log} do
      ids = for i <- 1..6, do: TransactionID.encode({1, i})
      transactions = Enum.map(ids, &{&1, {:data, &1}})
      {:ok, log} = Log.append_transactions(log, TransactionID.encode({0, 0}), transactions)
      {:ok, log: log, transactions: transactions}
    end

    test "limits the number of returned transactions", %{log: log, transactions: transactions} do
      assert Log.transactions_from(log, TransactionID.encode({0, 0}), :newest, 3) ==
               Enum.take(transactions, 3)
    end

    test "a limit of 0 returns an empty list", %{log: log} do
      assert Log.transactions_from(log, TransactionID.encode({0, 0}), :newest, 0) == []
    end

    test "a limit larger than the available entries returns everything", %{
      log: log,
      transactions: transactions
    } do
      assert Log.transactions_from(log, TransactionID.encode({0, 0}), :newest, 100) ==
               transactions
    end

    test ":infinity behaves like transactions_from/3", %{log: log, transactions: transactions} do
      assert Log.transactions_from(log, TransactionID.encode({1, 2}), :newest, :infinity) ==
               Log.transactions_from(log, TransactionID.encode({1, 2}), :newest)

      assert Log.transactions_from(log, TransactionID.encode({0, 0}), :newest, :infinity) ==
               transactions
    end

    test "the limit applies within the from/to bounds", %{log: log, transactions: transactions} do
      assert Log.transactions_from(
               log,
               TransactionID.encode({1, 2}),
               TransactionID.encode({1, 5}),
               2
             ) ==
               Enum.slice(transactions, 2, 2)
    end

    test "honors :newest_safe as the upper bound", %{log: log, transactions: transactions} do
      {:ok, log} = Log.commit_up_to(log, TransactionID.encode({1, 4}))

      assert Log.transactions_from(log, TransactionID.encode({1, 1}), :newest_safe, 10) ==
               Enum.slice(transactions, 1, 3)
    end
  end
end
