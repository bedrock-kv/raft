defmodule Bedrock.Raft.ElectionSafetyTest do
  use ExUnit.Case, async: true

  alias Bedrock.Raft
  alias Bedrock.Raft.Log
  alias Bedrock.Raft.Log.InMemoryLog
  alias Bedrock.Raft.Mode.Candidate
  alias Bedrock.Raft.Mode.Follower

  defmodule Interface do
    @moduledoc false

    def timer(name) do
      owner = self()
      send(owner, {:timer_started, name})
      fn -> send(owner, {:timer_cancelled, name}) end
    end

    def send_event(peer, event) do
      send(self(), {:sent, peer, event})
      :ok
    end

    def leadership_changed(leadership) do
      send(self(), {:leadership_changed, leadership})
      :ok
    end

    def consensus_reached(_log, _transaction_id, _consistency), do: :ok
  end

  test "a candidate persists its self-vote and cannot vote for a same-term competitor" do
    raft =
      Raft.new(:a, [:b, :c], InMemoryLog.new(), Interface)
      |> Raft.handle_event(:election, :timer)

    assert %Candidate{term: 1, voted_for: :a} = raft.mode
    assert Log.current_term(Raft.log(raft)) == 1
    assert Log.voted_for(Raft.log(raft)) == :a

    flush_mailbox()
    unchanged = Raft.handle_event(raft, {:request_vote, 1, {9, 9}}, :b)

    assert %Candidate{voted_for: :a} = unchanged.mode
    refute_receive {:sent, :b, {:vote, 1}}
  end

  test "a candidate timeout starts and persists a new election term" do
    raft =
      Raft.new(:a, [:b, :c], InMemoryLog.new(), Interface)
      |> Raft.handle_event(:election, :timer)
      |> Raft.handle_event(:election, :timer)

    assert %Candidate{term: 2, voted_for: :a, votes: []} = raft.mode
    assert Log.current_term(Raft.log(raft)) == 2
    assert Log.voted_for(Raft.log(raft)) == :a
    assert_received {:sent, :b, {:request_vote, 2, {0, 0}}}
    assert_received {:sent, :c, {:request_vote, 2, {0, 0}}}
  end

  test "a higher-term vote request is persisted even when the candidate log is rejected" do
    {:ok, log} = Log.append_transactions(InMemoryLog.new(), {0, 0}, [{{1, 1}, :local}])
    {:ok, log} = Log.save_election_state(log, 1, :old_candidate)
    raft = Raft.new(:a, [:b, :c], log, Interface)

    flush_mailbox()
    raft = Raft.handle_event(raft, {:request_vote, 2, {0, 0}}, :b)

    assert %Follower{term: 2, voted_for: nil} = raft.mode
    assert Log.current_term(Raft.log(raft)) == 2
    assert Log.voted_for(Raft.log(raft)) == nil
    refute_receive {:sent, :b, {:vote, 2}}
  end

  test "higher-term responses persist the term and step a candidate down" do
    for event <- [{:vote, 2}, {:append_entries_ack, 2, true, {0, 0}}] do
      raft =
        Raft.new(:a, [:b, :c], InMemoryLog.new(), Interface)
        |> Raft.handle_event(:election, :timer)

      flush_mailbox()
      raft = Raft.handle_event(raft, event, :b)

      assert %Follower{term: 2, leader: :undecided, voted_for: nil} = raft.mode
      assert Log.current_term(Raft.log(raft)) == 2
      assert Log.voted_for(Raft.log(raft)) == nil
    end
  end

  test "a higher-term heartbeat cancels the candidate election timer" do
    raft =
      Raft.new(:a, [:b, :c], InMemoryLog.new(), Interface)
      |> Raft.handle_event(:election, :timer)

    owner = self()
    raft = %{raft | mode: %{raft.mode | cancel_timer_fn: fn -> send(owner, :timer_cancelled) end}}

    flush_mailbox()
    raft = Raft.handle_event(raft, {:append_entries, 2, {0, 0}, [], {0, 0}}, :b)

    assert %Follower{term: 2, leader: :b} = raft.mode
    assert_received :timer_cancelled
  end

  test "a higher-term heartbeat from the same leader reports the new term" do
    {:ok, log} = Log.save_election_state(InMemoryLog.new(), 3, nil)
    initial_transaction_id = Log.initial_transaction_id(log)
    raft = Raft.new(:a, [:b, :c], log, Interface)

    raft =
      Raft.handle_event(
        raft,
        {:append_entries, 3, initial_transaction_id, [], initial_transaction_id},
        :b
      )

    flush_mailbox()

    raft =
      Raft.handle_event(
        raft,
        {:append_entries, 4, initial_transaction_id, [], initial_transaction_id},
        :b
      )

    assert Raft.leadership(raft) == {:b, 4}
    assert_received {:leadership_changed, {:b, 4}}
    refute_receive {:leadership_changed, {:b, 4}}
  end

  test "a higher-term AppendEntries request clears the old vote before it is handled" do
    {:ok, log} = Log.save_election_state(InMemoryLog.new(), 1, :old_candidate)
    raft = Raft.new(:a, [:b, :c], log, Interface)

    flush_mailbox()
    raft = Raft.handle_event(raft, {:append_entries, 2, {0, 0}, [], {0, 0}}, :b)

    assert %Follower{term: 2, leader: :b, voted_for: nil} = raft.mode
    assert Log.current_term(Raft.log(raft)) == 2
    assert Log.voted_for(Raft.log(raft)) == nil
    assert_received {:sent, :b, {:append_entries_ack, 2, true, {0, 0}}}
  end

  test "same-term responses do not erase a follower vote" do
    {:ok, log} = Log.save_election_state(InMemoryLog.new(), 1, :b)
    raft = Raft.new(:a, [:b, :c], log, Interface)

    raft = Raft.handle_event(raft, {:vote, 1}, :noise)
    raft = Raft.handle_event(raft, {:append_entries_ack, 1, false, {0, 0}}, :noise)

    assert %Follower{term: 1, voted_for: :b} = raft.mode
    assert Log.voted_for(Raft.log(raft)) == :b

    flush_mailbox()
    raft = Raft.handle_event(raft, {:request_vote, 1, {0, 0}}, :c)
    assert %Follower{voted_for: :b} = raft.mode
    refute_receive {:sent, :c, {:vote, 1}}
  end

  test "a vote survives reconstruction and is resent only to the same candidate" do
    raft = Raft.new(:a, [:b, :c], InMemoryLog.new(), Interface)
    raft = Raft.handle_event(raft, {:request_vote, 1, {0, 0}}, :b)
    assert_received {:sent, :b, {:vote, 1}}

    reconstructed = Raft.new(:a, [:b, :c], Raft.log(raft), Interface)
    assert %Follower{term: 1, voted_for: :b} = reconstructed.mode

    flush_mailbox()
    reconstructed = Raft.handle_event(reconstructed, {:request_vote, 1, {0, 0}}, :b)
    assert_received {:sent, :b, {:vote, 1}}

    flush_mailbox()
    reconstructed = Raft.handle_event(reconstructed, {:request_vote, 1, {0, 0}}, :c)
    assert %Follower{voted_for: :b} = reconstructed.mode
    refute_receive {:sent, :c, {:vote, 1}}
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
