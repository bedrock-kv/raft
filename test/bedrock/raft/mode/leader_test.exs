defmodule Bedrock.Raft.Mode.LeaderTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Mox

  alias Bedrock.Raft.Log
  alias Bedrock.Raft.Log.InMemoryLog
  alias Bedrock.Raft.MockInterface
  alias Bedrock.Raft.Mode.Leader
  alias Bedrock.Raft.Mode.Leader.FollowerTracking

  setup :verify_on_exit!

  def mock_cancel, do: :ok

  setup do
    stub(MockInterface, :quorum_lost, fn _active, _total, _term -> :continue end)
    :ok
  end

  describe "new/5" do
    test "initializes leader with heartbeat timer" do
      term = 2
      quorum = 1
      peers = [:peer_1, :peer_2]
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)

      leader = Leader.new(term, quorum, peers, log, MockInterface)

      assert leader.term == term
      assert leader.quorum == quorum
      assert leader.peers == peers
      assert not is_nil(leader.cancel_timer_fn)
    end
  end

  describe "timer_ticked/2" do
    test "continues leadership when heartbeat timer ticks (no forced step-down)" do
      term = 2
      quorum = 1
      peers = [:peer_1, :peer_2]
      log = InMemoryLog.new()

      # Use different timestamps to simulate followers not seen recently
      # initialization
      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # During timer tick, use a later timestamp to make followers appear "not seen recently"
      # Called twice: once in active_followers, once in send_heartbeats_and_continue
      expect(MockInterface, :timestamp_in_ms, 2, fn -> 1200 end)
      # followers not seen in 100ms - called twice (active_followers + send_heartbeats)
      expect(MockInterface, :heartbeat_ms, 2, fn -> 100 end)

      # Now followers should be considered "not seen recently" and get heartbeats
      expect(MockInterface, :send_event, fn :peer_1, {:append_entries, 2, {0, 0}, [], {0, 0}} ->
        :ok
      end)

      expect(MockInterface, :send_event, fn :peer_2, {:append_entries, 2, {0, 0}, [], {0, 0}} ->
        :ok
      end)

      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)

      {:ok, leader} = Leader.timer_ticked(leader, :heartbeat)

      # Leader should still be active (not step down)
      assert leader.term == term
    end

    test "sends heartbeats to followers not recently seen" do
      term = 2
      quorum = 1
      peers = [:peer_1, :peer_2]
      log = InMemoryLog.new()

      # Use different timestamps to simulate passage of time
      # initialization
      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # During timer tick, use a later timestamp
      # Called twice: once in active_followers, once in send_heartbeats_and_continue
      expect(MockInterface, :timestamp_in_ms, 2, fn -> 1200 end)
      # check for followers not seen in 100ms - called twice
      expect(MockInterface, :heartbeat_ms, 2, fn -> 100 end)

      # Followers should be considered "not seen recently" and get heartbeats
      expect(MockInterface, :send_event, fn :peer_1, {:append_entries, 2, {0, 0}, [], {0, 0}} ->
        :ok
      end)

      expect(MockInterface, :send_event, fn :peer_2, {:append_entries, 2, {0, 0}, [], {0, 0}} ->
        :ok
      end)

      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)

      {:ok, _leader} = Leader.timer_ticked(leader, :heartbeat)
    end

    test "delegates quorum loss decision to interface" do
      term = 2
      # Requires 2 followers to maintain quorum
      quorum = 2
      peers = [:peer_1, :peer_2]
      log = InMemoryLog.new()

      # Use different timestamps to simulate followers becoming inactive
      # initialization
      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # During timer tick, use a later timestamp to simulate long inactive period
      # 1000ms later
      expect(MockInterface, :timestamp_in_ms, fn -> 2000 end)
      # check for followers not seen in 50ms
      expect(MockInterface, :heartbeat_ms, fn -> 50 end)

      # Configure interface to step down when quorum is lost
      expect(MockInterface, :quorum_lost, fn 0, 2, 2 -> :step_down end)

      # Should step down when interface decides to
      result = Leader.timer_ticked(leader, :heartbeat)
      assert result == :become_follower
    end

    test "continues leadership when interface decides to continue despite quorum loss" do
      term = 2
      # Requires 2 followers to maintain quorum
      quorum = 2
      peers = [:peer_1, :peer_2]
      log = InMemoryLog.new()

      # Use different timestamps to simulate followers becoming inactive
      # initialization
      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # During timer tick, use a later timestamp
      # called twice in send_heartbeats_and_continue
      expect(MockInterface, :timestamp_in_ms, 2, fn -> 2000 end)
      # called twice
      expect(MockInterface, :heartbeat_ms, 2, fn -> 50 end)

      # Configure interface to continue despite quorum loss
      expect(MockInterface, :quorum_lost, fn 0, 2, 2 -> :continue end)

      # Should send heartbeats and continue
      expect(MockInterface, :send_event, fn :peer_1, {:append_entries, 2, {0, 0}, [], {0, 0}} ->
        :ok
      end)

      expect(MockInterface, :send_event, fn :peer_2, {:append_entries, 2, {0, 0}, [], {0, 0}} ->
        :ok
      end)

      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)

      {:ok, leader} = Leader.timer_ticked(leader, :heartbeat)
      assert leader.term == term
    end
  end

  describe "vote_requested/4" do
    test "steps down when receiving vote request with higher term" do
      term = 2
      quorum = 1
      peers = [:peer_1, :peer_2]
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # Vote request with higher term should cause step-down
      result = Leader.vote_requested(leader, 3, :peer_1, {3, 1})
      assert result == :become_follower
    end

    test "ignores vote request with lower or equal term" do
      term = 2
      quorum = 1
      peers = [:peer_1, :peer_2]
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # Vote request with same term should be ignored
      {:ok, leader} = Leader.vote_requested(leader, 2, :peer_1, {2, 1})
      assert leader.term == 2

      # Vote request with lower term should be ignored
      {:ok, leader} = Leader.vote_requested(leader, 1, :peer_1, {1, 1})
      assert leader.term == 2
    end
  end

  describe "append_entries_received/6" do
    test "steps down when receiving append_entries with higher term" do
      term = 2
      quorum = 1
      peers = [:peer_1, :peer_2]
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # AppendEntries with higher term should cause step-down
      result = Leader.append_entries_received(leader, 3, {0, 0}, [], {0, 0}, :peer_1)
      assert result == :become_follower
    end

    test "ignores append_entries with lower or equal term" do
      term = 2
      quorum = 1
      peers = [:peer_1, :peer_2]
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # AppendEntries with lower term should be ignored
      {:ok, leader} = Leader.append_entries_received(leader, 1, {0, 0}, [], {0, 0}, :peer_1)
      assert leader.term == 2
    end
  end

  describe "append_entries_ack_received/6" do
    test "ignores responses from peers outside the cluster" do
      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 0, [], InMemoryLog.new(), MockInterface)

      assert {:ok, ^leader} =
               Leader.append_entries_ack_received(leader, 2, true, {0, 0}, {0, 0}, :unknown_peer)
    end

    test "does not directly commit an entry from a previous term" do
      log = InMemoryLog.new()
      initial_transaction_id = Log.initial_transaction_id(log)
      previous_term_transaction_id = {1, 1}

      {:ok, log} =
        Log.append_transactions(log, initial_transaction_id, [
          {previous_term_transaction_id, :previous_term}
        ])

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], log, MockInterface)

      expect(MockInterface, :timestamp_in_ms, fn -> 1010 end)

      {:ok, leader} =
        Leader.append_entries_ack_received(
          leader,
          2,
          true,
          previous_term_transaction_id,
          previous_term_transaction_id,
          :peer_1
        )

      assert Log.newest_safe_transaction_id(leader.log) == initial_transaction_id
    end

    test "commits a previous-term prefix indirectly with a current-term entry" do
      log = InMemoryLog.new()
      initial_transaction_id = Log.initial_transaction_id(log)
      previous_term_transaction_id = {1, 1}
      current_term_transaction_id = {2, 2}

      {:ok, log} =
        Log.append_transactions(log, initial_transaction_id, [
          {previous_term_transaction_id, :previous_term},
          {current_term_transaction_id, :current_term}
        ])

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], log, MockInterface)

      expect(MockInterface, :timestamp_in_ms, fn -> 1010 end)

      expect(MockInterface, :consensus_reached, fn committed_log,
                                                   ^current_term_transaction_id,
                                                   :latest ->
        assert Log.newest_safe_transaction_id(committed_log) == current_term_transaction_id
        :ok
      end)

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, ^current_term_transaction_id, [],
                                             ^current_term_transaction_id} ->
        :ok
      end)

      {:ok, leader} =
        Leader.append_entries_ack_received(
          leader,
          2,
          true,
          current_term_transaction_id,
          current_term_transaction_id,
          :peer_1
        )

      assert Log.newest_safe_transaction_id(leader.log) == current_term_transaction_id

      assert Log.transactions_from(leader.log, initial_transaction_id, :newest_safe) == [
               {previous_term_transaction_id, :previous_term},
               {current_term_transaction_id, :current_term}
             ]
    end

    test "rejection backtracks and converges without advancing matchIndex" do
      t0 = {0, 0}
      t1 = {2, 1}
      t2 = {2, 2}

      {:ok, log} =
        InMemoryLog.new()
        |> Log.append_transactions(t0, [{t1, :one}, {t2, :two}])

      expect(MockInterface, :timestamp_in_ms, 4, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], log, MockInterface)

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, ^t1, [{^t2, :two}], ^t0} ->
        :ok
      end)

      {:ok, leader} = Leader.append_entries_ack_received(leader, 2, false, t2, t2, :peer_1)

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == t0

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, ^t0, [{^t1, :one}, {^t2, :two}],
                                             ^t0} ->
        :ok
      end)

      {:ok, leader} = Leader.append_entries_ack_received(leader, 2, false, t1, t1, :peer_1)

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == t0

      expect(MockInterface, :consensus_reached, fn _, ^t2, :latest -> :ok end)

      expect(MockInterface, :send_event, fn :peer_1, {:append_entries, 2, ^t2, [], ^t2} -> :ok end)

      {:ok, leader} = Leader.append_entries_ack_received(leader, 2, true, t2, t2, :peer_1)

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == t2
      assert Log.newest_safe_transaction_id(leader.log) == t2
    end

    test "ignores a successful response for an ID absent from the leader log" do
      t0 = {0, 0}
      nonexistent_transaction_id = {9, 9}

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], InMemoryLog.new(), MockInterface)

      {:ok, leader} =
        Leader.append_entries_ack_received(
          leader,
          2,
          true,
          nonexistent_transaction_id,
          nonexistent_transaction_id,
          :peer_1
        )

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == t0
      assert Log.newest_safe_transaction_id(leader.log) == t0
    end

    test "a delayed old success cannot regress matchIndex or the send cursor" do
      transactions = for index <- 1..3, do: {{2, index}, index}

      {:ok, log} =
        InMemoryLog.new()
        |> Log.append_transactions({0, 0}, transactions)

      expect(MockInterface, :timestamp_in_ms, 3, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 2, [:peer_1, :peer_2], log, MockInterface)

      {:ok, leader} = Leader.append_entries_ack_received(leader, 2, true, {2, 3}, {2, 3}, :peer_1)
      {:ok, leader} = Leader.append_entries_ack_received(leader, 2, true, {2, 1}, {2, 1}, :peer_1)

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == {2, 3}

      assert FollowerTracking.send_cursor_transaction_id(leader.follower_tracking, :peer_1) ==
               {2, 3}

      assert Log.newest_safe_transaction_id(leader.log) == {0, 0}
    end

    test "continues with the next batch after a successful ten-entry response" do
      t0 = {0, 0}
      transactions = for index <- 1..12, do: {{2, index}, index}
      first_batch = Enum.take(transactions, 10)
      second_batch = Enum.drop(transactions, 10)

      {:ok, log} = InMemoryLog.new() |> Log.append_transactions(t0, transactions)

      expect(MockInterface, :timestamp_in_ms, 3, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], log, MockInterface)

      true = :ets.update_element(leader.follower_tracking.table, :peer_1, {2, t0})

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, ^t0, ^first_batch, ^t0} ->
        :ok
      end)

      {:ok, leader} = Leader.append_entries_ack_received(leader, 2, true, t0, t0, :peer_1)

      expect(MockInterface, :consensus_reached, fn _, {2, 10}, :behind -> :ok end)

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {2, 10}, ^second_batch, {2, 10}} ->
        :ok
      end)

      {:ok, leader} =
        Leader.append_entries_ack_received(leader, 2, true, {2, 10}, {2, 10}, :peer_1)

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) ==
               {2, 10}

      assert Log.newest_safe_transaction_id(leader.log) == {2, 10}
    end
  end

  describe "pipelined replication" do
    test "consecutive adds send disjoint batches before any acknowledgement" do
      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], InMemoryLog.new(), MockInterface)

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {0, 0}, [{{2, 1}, :one}], {0, 0}} ->
        :ok
      end)

      {:ok, leader, _} = Leader.add_transaction(leader, :one)

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {2, 1}, [{{2, 2}, :two}], {0, 0}} ->
        :ok
      end)

      {:ok, leader, _} = Leader.add_transaction(leader, :two)

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {2, 2}, [{{2, 3}, :three}],
                                             {0, 0}} ->
        :ok
      end)

      {:ok, leader, _} = Leader.add_transaction(leader, :three)

      assert FollowerTracking.send_cursor_transaction_id(leader.follower_tracking, :peer_1) ==
               {2, 3}

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == {0, 0}
    end

    test "a success for an earlier batch does not regress the send cursor" do
      expect(MockInterface, :timestamp_in_ms, 2, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], InMemoryLog.new(), MockInterface)

      # Three adds; each send advances the cursor past the entry it carries.
      expect(MockInterface, :send_event, 3, fn :peer_1, {:append_entries, 2, _, [_], {0, 0}} ->
        :ok
      end)

      {:ok, leader, _} = Leader.add_transaction(leader, :one)
      {:ok, leader, _} = Leader.add_transaction(leader, :two)
      {:ok, leader, _} = Leader.add_transaction(leader, :three)

      assert FollowerTracking.send_cursor_transaction_id(leader.follower_tracking, :peer_1) ==
               {2, 3}

      # A delayed success for the first batch arrives. It advances matchIndex
      # and commits, but must not drag the cursor back to {2, 1}: the commit
      # notification goes out from the send-advanced cursor, carrying nothing.
      expect(MockInterface, :consensus_reached, fn _, {2, 1}, :behind -> :ok end)

      expect(MockInterface, :send_event, fn :peer_1, {:append_entries, 2, {2, 3}, [], {2, 1}} ->
        :ok
      end)

      {:ok, leader} = Leader.append_entries_ack_received(leader, 2, true, {2, 1}, {2, 1}, :peer_1)

      assert FollowerTracking.send_cursor_transaction_id(leader.follower_tracking, :peer_1) ==
               {2, 3}

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == {2, 1}
    end

    test "a lost request is recovered through rejection backtracking" do
      transactions = for index <- 1..3, do: {{2, index}, index}
      {:ok, log} = InMemoryLog.new() |> Log.append_transactions({0, 0}, transactions)

      # The cursor starts at the newest entry, as if everything had been sent
      # and lost. Each heartbeat probe is rejected and backtracks the cursor.
      expect(MockInterface, :timestamp_in_ms, 3, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], log, MockInterface)

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {2, 2}, [{{2, 3}, 3}], {0, 0}} ->
        :ok
      end)

      {:ok, leader} =
        Leader.append_entries_ack_received(leader, 2, false, {2, 3}, {2, 3}, :peer_1)

      assert FollowerTracking.send_cursor_transaction_id(leader.follower_tracking, :peer_1) ==
               {2, 3}

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {2, 1},
                                             [{{2, 2}, 2}, {{2, 3}, 3}], {0, 0}} ->
        :ok
      end)

      {:ok, leader} =
        Leader.append_entries_ack_received(leader, 2, false, {2, 2}, {2, 2}, :peer_1)

      expect(MockInterface, :timestamp_in_ms, fn -> 1010 end)
      expect(MockInterface, :consensus_reached, fn _, {2, 3}, :latest -> :ok end)

      expect(MockInterface, :send_event, fn :peer_1, {:append_entries, 2, {2, 3}, [], {2, 3}} ->
        :ok
      end)

      {:ok, leader} = Leader.append_entries_ack_received(leader, 2, true, {2, 3}, {2, 3}, :peer_1)

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == {2, 3}
      assert Log.newest_safe_transaction_id(leader.log) == {2, 3}
    end
  end

  describe "add_transaction/2" do
    test "successfully adds transaction and sends append_entries to followers" do
      term = 2
      quorum = 1
      peers = [:peer_1, :peer_2]
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # Expect append_entries to be sent to both peers after transaction addition
      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {0, 0}, [{{2, 1}, "test_data"}],
                                             {0, 0}} ->
        :ok
      end)

      expect(MockInterface, :send_event, fn :peer_2,
                                            {:append_entries, 2, {0, 0}, [{{2, 1}, "test_data"}],
                                             {0, 0}} ->
        :ok
      end)

      {:ok, leader, txn_id} = Leader.add_transaction(leader, "test_data")

      assert txn_id == {2, 1}
      assert leader.id_sequence == 1
    end

    test "immediately reaches consensus for single-node cluster (quorum = 0)" do
      term = 1
      quorum = 0
      peers = []
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # For single-node clusters, consensus should be reached immediately
      expect(MockInterface, :consensus_reached, fn log, {1, 1}, :latest ->
        # Verify the log and transaction_id are correct
        assert log != nil
        :ok
      end)

      {:ok, leader, txn_id} = Leader.add_transaction(leader, "single_node_data")

      assert txn_id == {1, 1}
      assert leader.id_sequence == 1

      # Verify the transaction is committed in the log
      assert Log.newest_safe_transaction_id(leader.log) == {1, 1}
      assert Log.newest_transaction_id(leader.log) == {1, 1}
    end

    test "handles multiple transactions in single-node cluster correctly" do
      term = 1
      quorum = 0
      peers = []
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # First transaction
      expect(MockInterface, :consensus_reached, fn _, {1, 1}, :latest -> :ok end)
      {:ok, leader, txn_id1} = Leader.add_transaction(leader, "data1")
      assert txn_id1 == {1, 1}

      # Second transaction
      expect(MockInterface, :consensus_reached, fn _, {1, 2}, :latest -> :ok end)
      {:ok, leader, txn_id2} = Leader.add_transaction(leader, "data2")
      assert txn_id2 == {1, 2}

      # Third transaction
      expect(MockInterface, :consensus_reached, fn _, {1, 3}, :latest -> :ok end)
      {:ok, leader, txn_id3} = Leader.add_transaction(leader, "data3")
      assert txn_id3 == {1, 3}

      # Verify all transactions are committed
      assert Log.newest_safe_transaction_id(leader.log) == {1, 3}
      assert Log.newest_transaction_id(leader.log) == {1, 3}

      # Verify log contains all transactions
      transactions = Log.transactions_from(leader.log, {0, 0}, :newest)
      assert length(transactions) == 3
      assert transactions == [{{1, 1}, "data1"}, {{1, 2}, "data2"}, {{1, 3}, "data3"}]
    end

    test "single-node cluster consensus works from term 0" do
      term = 0
      quorum = 0
      peers = []
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # Transaction in term 0 should work
      expect(MockInterface, :consensus_reached, fn _, {0, 1}, :latest -> :ok end)
      {:ok, leader, txn_id} = Leader.add_transaction(leader, "term_zero_data")

      assert txn_id == {0, 1}
      assert Log.newest_safe_transaction_id(leader.log) == {0, 1}
    end

    test "single-node cluster doesn't send append_entries to any peers" do
      term = 1
      quorum = 0
      peers = []
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # No send_event calls should be made to peers since there are none
      expect(MockInterface, :consensus_reached, fn _, {1, 1}, :latest -> :ok end)

      {:ok, _leader, txn_id} = Leader.add_transaction(leader, "no_peers_data")
      assert txn_id == {1, 1}
    end

    test "single-node cluster passes committed log to consensus_reached callback" do
      term = 1
      quorum = 0
      peers = []
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # Verify that the log passed to consensus_reached has the transaction committed
      expect(MockInterface, :consensus_reached, fn committed_log, {1, 1}, :latest ->
        # The committed log should have the transaction as both newest and newest_safe
        assert Log.newest_transaction_id(committed_log) == {1, 1}
        assert Log.newest_safe_transaction_id(committed_log) == {1, 1}
        :ok
      end)

      {:ok, leader, txn_id} = Leader.add_transaction(leader, "test_data")

      assert txn_id == {1, 1}
      # Verify the leader's log is also correctly updated
      assert Log.newest_safe_transaction_id(leader.log) == {1, 1}
      assert Log.newest_transaction_id(leader.log) == {1, 1}
    end

    test "leader initializes id_sequence from existing log" do
      term = 0
      quorum = 0
      peers = []
      log = InMemoryLog.new()

      # Pre-populate log with existing transactions using the Log protocol
      {:ok, log} =
        Log.append_transactions(log, {0, 0}, [
          {{0, 1}, "transaction 1"},
          {{0, 2}, "transaction 2"},
          {{0, 3}, "transaction 3"}
        ])

      {:ok, log} = Log.commit_up_to(log, {0, 3})

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # Leader should initialize id_sequence to 3 (index of {0, 3})
      assert leader.id_sequence == 3

      # Next transaction should be {0, 4}
      expect(MockInterface, :consensus_reached, fn _, {0, 4}, :latest -> :ok end)
      {:ok, leader, txn_id} = Leader.add_transaction(leader, "transaction 4")

      assert txn_id == {0, 4}
      assert leader.id_sequence == 4
    end

    test "leader handles empty log initialization correctly" do
      term = 1
      quorum = 0
      peers = []
      # Empty log
      log = InMemoryLog.new()

      expect(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(term, quorum, peers, log, MockInterface)

      # For empty log, id_sequence should be 0
      assert leader.id_sequence == 0

      # First transaction should be {1, 1}
      expect(MockInterface, :consensus_reached, fn _, {1, 1}, :latest -> :ok end)
      {:ok, leader, txn_id} = Leader.add_transaction(leader, "first transaction")

      assert txn_id == {1, 1}
      assert leader.id_sequence == 1
    end
  end

  describe "rejection hints" do
    test "a far-behind follower is repositioned by a single rejection" do
      t0 = {0, 0}
      transactions = for index <- 1..25, do: {{2, index}, index}
      first_batch = Enum.take(transactions, 10)

      {:ok, log} = InMemoryLog.new() |> Log.append_transactions(t0, transactions)

      expect(MockInterface, :timestamp_in_ms, 2, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], log, MockInterface)

      # A heartbeat probe at the newest entry was rejected by an empty
      # follower. Its hint repositions the cursor to the log start in one
      # round trip instead of twenty-five.
      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, ^t0, ^first_batch, ^t0} ->
        :ok
      end)

      {:ok, leader} = Leader.append_entries_ack_received(leader, 2, false, {2, 25}, t0, :peer_1)

      assert FollowerTracking.send_cursor_transaction_id(leader.follower_tracking, :peer_1) ==
               {2, 10}

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == t0
    end

    test "a hint absent from the leader's log falls back to one-step backtracking" do
      transactions = for index <- 1..3, do: {{2, index}, index}
      {:ok, log} = InMemoryLog.new() |> Log.append_transactions({0, 0}, transactions)

      expect(MockInterface, :timestamp_in_ms, 2, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], log, MockInterface)

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {2, 2}, [{{2, 3}, 3}], {0, 0}} ->
        :ok
      end)

      {:ok, leader} =
        Leader.append_entries_ack_received(leader, 2, false, {2, 3}, {1, 2}, :peer_1)

      assert FollowerTracking.send_cursor_transaction_id(leader.follower_tracking, :peer_1) ==
               {2, 3}
    end

    test "a hint at or beyond the rejected entry is ignored" do
      transactions = for index <- 1..3, do: {{2, index}, index}
      {:ok, log} = InMemoryLog.new() |> Log.append_transactions({0, 0}, transactions)

      expect(MockInterface, :timestamp_in_ms, 2, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], log, MockInterface)

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {2, 1},
                                             [{{2, 2}, 2}, {{2, 3}, 3}], {0, 0}} ->
        :ok
      end)

      {:ok, leader} =
        Leader.append_entries_ack_received(leader, 2, false, {2, 2}, {2, 3}, :peer_1)

      assert FollowerTracking.send_cursor_transaction_id(leader.follower_tracking, :peer_1) ==
               {2, 3}
    end

    test "a delayed rejection cannot drag the cursor below matchIndex" do
      t0 = {0, 0}
      transactions = for index <- 1..50, do: {{2, index}, index}
      retry_batch = Enum.slice(transactions, 30, 10)

      {:ok, log} = InMemoryLog.new() |> Log.append_transactions(t0, transactions)

      expect(MockInterface, :timestamp_in_ms, 3, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)
      leader = Leader.new(2, 1, [:peer_1], log, MockInterface)

      # The follower has confirmed replication through {2, 30}.
      expect(MockInterface, :consensus_reached, fn _, {2, 30}, :behind -> :ok end)

      expect(MockInterface, :send_event, fn :peer_1, {:append_entries, 2, {2, 50}, [], {2, 30}} ->
        :ok
      end)

      {:ok, leader} =
        Leader.append_entries_ack_received(leader, 2, true, {2, 30}, {2, 30}, :peer_1)

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == {2, 30}

      # A delayed rejection from when the follower was still empty arrives:
      # prev {2, 40} is above matchIndex, but the stale hint {0, 0} is far
      # below it. The retry probe must clamp to the confirmed match position
      # instead of replaying the whole prefix.
      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {2, 30}, ^retry_batch, {2, 30}} ->
        :ok
      end)

      {:ok, leader} =
        Leader.append_entries_ack_received(leader, 2, false, {2, 40}, t0, :peer_1)

      assert FollowerTracking.send_cursor_transaction_id(leader.follower_tracking, :peer_1) >=
               {2, 30}

      assert FollowerTracking.match_transaction_id(leader.follower_tracking, :peer_1) == {2, 30}
    end
  end

  describe "append_entries_batch_size" do
    test "defaults to 10" do
      stub(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)

      leader = Leader.new(2, 1, [:peer_1], InMemoryLog.new(), MockInterface)

      assert leader.append_entries_batch_size == 10
      assert Leader.default_append_entries_batch_size() == 10
    end

    test "Leader.new/6 validates the batch size directly" do
      for bad <- [0, -1, :lots, "10"] do
        assert_raise ArgumentError, ~r/append_entries_batch_size/, fn ->
          Leader.new(2, 1, [:peer_1], InMemoryLog.new(), MockInterface,
            append_entries_batch_size: bad
          )
        end
      end
    end

    test "a custom batch size bounds catch-up batches and continues on success" do
      log = InMemoryLog.new()
      t0 = Log.initial_transaction_id(log)

      {:ok, log} = Log.append_transactions(log, t0, Enum.map(1..7, fn i -> {{2, i}, i} end))

      stub(MockInterface, :timestamp_in_ms, fn -> 1000 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_cancel/0 end)

      leader = Leader.new(2, 1, [:peer_1], log, MockInterface, append_entries_batch_size: 3)

      assert leader.append_entries_batch_size == 3

      # A rejection whose hint points at the log start repositions the cursor
      # and sends the first batch: exactly 3 entries.
      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, ^t0,
                                             [{{2, 1}, 1}, {{2, 2}, 2}, {{2, 3}, 3}], ^t0} ->
        :ok
      end)

      {:ok, leader} = Leader.append_entries_ack_received(leader, 2, false, {2, 7}, t0, :peer_1)

      # Success for that batch commits (quorum of one follower) and continues
      # with the next batch of 3 from the advanced cursor.
      expect(MockInterface, :consensus_reached, fn _, {2, 3}, :behind -> :ok end)

      expect(MockInterface, :send_event, fn :peer_1,
                                            {:append_entries, 2, {2, 3},
                                             [{{2, 4}, 4}, {{2, 5}, 5}, {{2, 6}, 6}], {2, 3}} ->
        :ok
      end)

      {:ok, _leader} =
        Leader.append_entries_ack_received(leader, 2, true, {2, 3}, {2, 3}, :peer_1)
    end
  end
end
