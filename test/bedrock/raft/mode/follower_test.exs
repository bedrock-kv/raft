defmodule Bedrock.Raft.Mode.FollowerTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Mox

  alias Bedrock.Raft.Log
  alias Bedrock.Raft.Log.InMemoryLog
  alias Bedrock.Raft.MockInterface
  alias Bedrock.Raft.Mode.Follower

  setup :verify_on_exit!

  def mock_cancel, do: :ok

  describe "new/3" do
    test "initializes with given term and log" do
      term = 1
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)

      follower = Follower.new(term, log, MockInterface, :peer_0)
      assert follower.term == term
      assert follower.leader == :undecided
      assert not is_nil(follower.cancel_timer_fn)
    end
  end

  describe "vote_requested/4" do
    test "votes for a candidate when conditions are met" do
      term = 1
      log = InMemoryLog.new()

      candidate = :peer_1
      candidate_last_transaction = {1, 1}

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      expect(MockInterface, :send_event, fn ^candidate, {:vote, ^term} -> :ok end)

      {:ok, follower} =
        Follower.vote_requested(follower, term, candidate, candidate_last_transaction)

      assert follower.voted_for == candidate
    end

    test "rejects candidate with older log term" do
      term = 2
      {:ok, log} = InMemoryLog.new() |> Log.append_transactions({0, 0}, [{{1, 1}, "data1"}])
      {:ok, log} = log |> Log.append_transactions({1, 1}, [{{2, 2}, "data2"}])

      candidate = :peer_1
      # older term despite higher index
      candidate_last_transaction = {1, 5}

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      {:ok, follower} =
        Follower.vote_requested(follower, term, candidate, candidate_last_transaction)

      assert follower.voted_for == nil
    end

    test "accepts candidate with same term but higher index" do
      term = 2
      {:ok, log} = InMemoryLog.new() |> Log.append_transactions({0, 0}, [{{2, 1}, "data1"}])

      candidate = :peer_1
      # same term, higher index
      candidate_last_transaction = {2, 3}

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      expect(MockInterface, :send_event, fn ^candidate, {:vote, ^term} -> :ok end)

      {:ok, follower} =
        Follower.vote_requested(follower, term, candidate, candidate_last_transaction)

      assert follower.voted_for == candidate
    end

    test "rejects candidate with same term but lower index" do
      term = 2
      {:ok, log} = InMemoryLog.new() |> Log.append_transactions({0, 0}, [{{2, 5}, "data1"}])

      candidate = :peer_1
      # same term, lower index
      candidate_last_transaction = {2, 3}

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      {:ok, follower} =
        Follower.vote_requested(follower, term, candidate, candidate_last_transaction)

      assert follower.voted_for == nil
    end

    test "does not vote for a candidate when already voted for another" do
      term = 1
      log = InMemoryLog.new()
      candidate = :peer_1
      candidate_last_transaction = {1, 1}

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      expect(MockInterface, :send_event, fn ^candidate, {:vote, ^term} -> :ok end)

      {:ok, follower} =
        Follower.vote_requested(follower, term, candidate, candidate_last_transaction)

      assert follower.voted_for == candidate

      candidate = :peer_2
      candidate_last_transaction = {1, 2}

      {:ok, follower} =
        Follower.vote_requested(follower, term, candidate, candidate_last_transaction)

      assert follower.voted_for == :peer_1
    end
  end

  describe "append_entries_received/6" do
    test "resets timer and acks the new leader when leader's term is greater" do
      term = 1
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      p = Follower.new(term, log, MockInterface, :peer_0)

      t0 = {0, 0}
      transactions = [{{2, 1}, "another_tx"}]
      t1 = {2, 1}
      leader = :peer_1

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {^leader, 2} -> :ok end)
      expect(MockInterface, :send_event, fn :peer_1, {:append_entries_ack, 2, ^t1} -> :ok end)
      expect(MockInterface, :consensus_reached, fn _, ^t1, :latest -> :ok end)

      {:ok, p} = Follower.append_entries_received(p, 2, t0, transactions, t1, leader)

      assert ^leader = p.leader
      assert 2 = p.term
    end

    test "ignores append entries with a lower term" do
      term = 2
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      prev_transaction_id = :some_tx_id
      transactions = []
      commit_transaction_id = :another_tx_id
      leader = :peer_1

      {:ok, follower} =
        Follower.append_entries_received(
          follower,
          1,
          prev_transaction_id,
          transactions,
          commit_transaction_id,
          leader
        )

      assert follower.leader == :undecided
    end

    test "accepts append_entries from any peer with higher term (prevents split-brain)" do
      term = 1
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0, :peer_1)

      # New leader with higher term should be accepted
      new_leader = :peer_2
      new_term = 2
      t0 = {0, 0}
      transactions = [{{2, 1}, "new_leader_tx"}]
      t1 = {2, 1}

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {^new_leader, ^new_term} -> :ok end)

      expect(MockInterface, :send_event, fn ^new_leader, {:append_entries_ack, ^new_term, ^t1} ->
        :ok
      end)

      expect(MockInterface, :consensus_reached, fn _, ^t1, :latest -> :ok end)

      {:ok, follower} =
        Follower.append_entries_received(follower, new_term, t0, transactions, t1, new_leader)

      assert follower.leader == new_leader
      assert follower.term == new_term
    end

    test "handles log consistency failure gracefully" do
      term = 2
      {:ok, log} = InMemoryLog.new() |> Log.append_transactions({0, 0}, [{{1, 1}, "existing"}])

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      leader = :peer_1
      # doesn't exist
      prev_transaction_id = {1, 99}
      transactions = [{{2, 2}, "new_data"}]
      commit_transaction_id = {2, 2}

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {^leader, ^term} -> :ok end)

      expect(MockInterface, :send_event, fn ^leader, {:append_entries_ack, ^term, {1, 1}} ->
        :ok
      end)

      {:ok, follower} =
        Follower.append_entries_received(
          follower,
          term,
          prev_transaction_id,
          transactions,
          commit_transaction_id,
          leader
        )

      assert follower.leader == leader
      assert follower.term == term
    end
  end

  describe "timer_ticked/2" do
    test "becomes candidate on election timeout" do
      term = 1
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      assert :become_candidate = Follower.timer_ticked(follower, :election)
    end

    test "ignores heartbeat timer" do
      term = 1
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      assert {:ok, _} = Follower.timer_ticked(follower, :heartbeat)
    end
  end

  describe "add_transaction/2" do
    test "returns error as followers cannot add transactions" do
      term = 1
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      assert {:error, :not_leader} = Follower.add_transaction(follower, "some_data")
    end
  end

  describe "append_entries_ack_received/4" do
    test "becomes follower when term is higher" do
      term = 1
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      assert :become_follower = Follower.append_entries_ack_received(follower, 2, {1, 1}, :peer_1)
    end

    test "ignores when term is lower" do
      term = 2
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      assert {:ok, _} = Follower.append_entries_ack_received(follower, 1, {1, 1}, :peer_1)
    end
  end

  describe "vote_received/3" do
    test "becomes follower when term is higher" do
      term = 1
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      assert :become_follower = Follower.vote_received(follower, 2, :peer_1)
    end

    test "ignores when term is lower" do
      term = 2
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      assert {:ok, _} = Follower.vote_received(follower, 1, :peer_1)
    end
  end

  describe "append_entries_received/6 with transaction skipping" do
    test "skips transactions already in log" do
      term = 1
      {:ok, log} = InMemoryLog.new() |> Log.append_transactions({0, 0}, [{{1, 1}, "data1"}])
      {:ok, log} = Log.commit_up_to(log, {1, 1})

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      leader = :peer_1
      prev_transaction_id = {0, 0}
      transactions = [{{1, 1}, "data1"}, {{1, 2}, "data2"}]
      commit_transaction_id = {1, 2}

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {^leader, ^term} -> :ok end)

      expect(MockInterface, :send_event, fn ^leader, {:append_entries_ack, ^term, {1, 2}} ->
        :ok
      end)

      expect(MockInterface, :consensus_reached, fn _, {1, 2}, :latest -> :ok end)

      {:ok, follower} =
        Follower.append_entries_received(
          follower,
          term,
          prev_transaction_id,
          transactions,
          commit_transaction_id,
          leader
        )

      assert Log.has_transaction_id?(follower.log, {1, 2})
    end

    test "preserves a committed suffix when an old tuple AppendEntries RPC is duplicated" do
      assert_duplicate_append_preserves_committed_suffix(:tuple)
    end

    test "preserves a committed suffix when an old binary AppendEntries RPC is duplicated" do
      assert_duplicate_append_preserves_committed_suffix(:binary)
    end

    test "truncates at the first conflicting index and appends from there" do
      term = 3
      leader = :peer_1
      log = InMemoryLog.new()
      initial_id = Log.initial_transaction_id(log)

      existing_transactions = [
        {Log.new_id(log, 1, 1), :matching},
        {Log.new_id(log, 1, 2), :old_2},
        {Log.new_id(log, 1, 3), :old_3},
        {Log.new_id(log, 1, 4), :old_4}
      ]

      incoming_transactions = [
        {Log.new_id(log, 1, 1), :matching},
        {Log.new_id(log, 2, 2), :new_2},
        {Log.new_id(log, 2, 3), :new_3}
      ]

      {:ok, log} = Log.append_transactions(log, initial_id, existing_transactions)
      {:ok, log} = Log.commit_up_to(log, Log.new_id(log, 1, 1))

      expect(MockInterface, :timer, 2, fn :election -> &mock_cancel/0 end)

      expect(MockInterface, :send_event, fn ^leader, {:append_entries_ack, ^term, {2, 3}} ->
        :ok
      end)

      follower = Follower.new(term, log, MockInterface, :peer_0, leader)

      {:ok, follower} =
        Follower.append_entries_received(
          follower,
          term,
          initial_id,
          incoming_transactions,
          Log.new_id(log, 1, 1),
          leader
        )

      assert Log.transactions_to(follower.log, :newest) == incoming_transactions
      assert Log.newest_safe_transaction_id(follower.log) == Log.new_id(log, 1, 1)
    end

    test "rejects a conflict that would truncate the committed prefix" do
      term = 3
      leader = :peer_1
      log = InMemoryLog.new()
      initial_id = Log.initial_transaction_id(log)

      existing_transactions = [
        {Log.new_id(log, 1, 1), :committed_1},
        {Log.new_id(log, 1, 2), :committed_2}
      ]

      conflicting_transactions = [
        {Log.new_id(log, 1, 1), :committed_1},
        {Log.new_id(log, 2, 2), :conflict}
      ]

      {:ok, log} = Log.append_transactions(log, initial_id, existing_transactions)
      committed_id = Log.new_id(log, 1, 2)
      {:ok, log} = Log.commit_up_to(log, committed_id)

      expect(MockInterface, :timer, 2, fn :election -> &mock_cancel/0 end)

      expect(MockInterface, :send_event, fn ^leader,
                                            {:append_entries_ack, ^term, ^committed_id} ->
        :ok
      end)

      follower = Follower.new(term, log, MockInterface, :peer_0, leader)

      {:ok, follower} =
        Follower.append_entries_received(
          follower,
          term,
          initial_id,
          conflicting_transactions,
          initial_id,
          leader
        )

      assert Log.transactions_to(follower.log, :newest) == existing_transactions
      assert Log.newest_safe_transaction_id(follower.log) == committed_id
    end

    test "handles empty transactions list" do
      term = 1
      log = InMemoryLog.new()

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      leader = :peer_1
      prev_transaction_id = {0, 0}
      transactions = []
      commit_transaction_id = {0, 0}

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {^leader, ^term} -> :ok end)

      expect(MockInterface, :send_event, fn ^leader, {:append_entries_ack, ^term, {0, 0}} ->
        :ok
      end)

      {:ok, follower} =
        Follower.append_entries_received(
          follower,
          term,
          prev_transaction_id,
          transactions,
          commit_transaction_id,
          leader
        )

      assert follower.leader == leader
    end
  end

  describe "consensus behind handling" do
    test "handles consensus_reached with :behind status when not all transactions committed" do
      term = 1
      {:ok, log} = InMemoryLog.new() |> Log.append_transactions({0, 0}, [{{1, 1}, "data1"}])

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      follower = Follower.new(term, log, MockInterface, :peer_0)

      leader = :peer_1
      prev_transaction_id = {1, 1}
      transactions = [{{1, 2}, "data2"}, {{1, 3}, "data3"}]
      commit_transaction_id = {1, 2}

      expect(MockInterface, :timer, fn _ -> &mock_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {^leader, ^term} -> :ok end)

      expect(MockInterface, :send_event, fn ^leader, {:append_entries_ack, ^term, {1, 3}} ->
        :ok
      end)

      expect(MockInterface, :consensus_reached, fn _, {1, 2}, :behind -> :ok end)

      {:ok, follower} =
        Follower.append_entries_received(
          follower,
          term,
          prev_transaction_id,
          transactions,
          commit_transaction_id,
          leader
        )

      assert follower.leader == leader
      assert Log.has_transaction_id?(follower.log, {1, 3})
    end
  end

  defp assert_duplicate_append_preserves_committed_suffix(format) do
    term = 1
    leader = :peer_1
    log = InMemoryLog.new(format)
    initial_id = Log.initial_transaction_id(log)

    transactions =
      for index <- 1..20 do
        {Log.new_id(log, term, index), {:command, index}}
      end

    {:ok, log} = Log.append_transactions(log, initial_id, transactions)
    newest_id = Log.new_id(log, term, 20)
    {:ok, log} = Log.commit_up_to(log, newest_id)

    expect(MockInterface, :timer, 2, fn :election -> &mock_cancel/0 end)

    expect(MockInterface, :send_event, fn ^leader, {:append_entries_ack, ^term, ^newest_id} ->
      :ok
    end)

    follower = Follower.new(term, log, MockInterface, :peer_0, leader)

    {:ok, follower} =
      Follower.append_entries_received(
        follower,
        term,
        initial_id,
        Enum.take(transactions, 10),
        initial_id,
        leader
      )

    assert Log.transactions_to(follower.log, :newest) == transactions
    assert Log.newest_transaction_id(follower.log) == newest_id
    assert Log.newest_safe_transaction_id(follower.log) == newest_id
  end
end
