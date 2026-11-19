defmodule Bedrock.Raft.HeartbeatIntervalTest do
  use ExUnit.Case, async: true

  alias Bedrock.Raft
  alias Bedrock.Raft.Log.InMemoryLog

  defmodule Interface do
    @moduledoc false
    # Records sent events in the process dictionary. The test sets the clock.
    @behaviour Bedrock.Raft.Interface

    def set_now(ms), do: Process.put(:now, ms)

    def take_sent do
      sent = Process.get(:sent, [])
      Process.put(:sent, [])
      Enum.reverse(sent)
    end

    @impl true
    def heartbeat_ms, do: 50
    @impl true
    def timestamp_in_ms, do: Process.get(:now, 0)
    @impl true
    def ignored_event(_, _), do: :ok
    @impl true
    def leadership_changed(_), do: :ok
    @impl true
    def timer(_kind), do: fn -> :ok end
    @impl true
    def send_event(to, event), do: Process.put(:sent, [{to, event} | Process.get(:sent, [])])
    @impl true
    def consensus_reached(_, _, _), do: :ok
    @impl true
    def quorum_lost(_, _, _), do: :continue
  end

  defp append_entries_recipients do
    for {to, {:append_entries, _, _, _, _}} <- Interface.take_sent(), do: to
  end

  defp tick(raft, ms) do
    Interface.set_now(ms)
    raft = Raft.handle_event(raft, :heartbeat, :timer)
    {raft, append_entries_recipients()}
  end

  defp ack(raft, from, ms) do
    Interface.set_now(ms)
    raft = Raft.handle_event(raft, {:append_entries_ack, 1, true, {0, 0}, {0, 0}}, from)
    _ = Interface.take_sent()
    raft
  end

  test "a leader sends each follower one AppendEntries per heartbeat interval" do
    Interface.set_now(0)
    raft = Raft.new(:a, [:b, :c], InMemoryLog.new(), Interface)

    # :a wins the election at t=0 with the vote of :b.
    raft = Raft.handle_event(raft, :election, :timer)
    _ = Interface.take_sent()
    raft = Raft.handle_event(raft, {:vote, 1}, :b)
    assert Raft.am_i_the_leader?(raft)

    # The new leader announces itself to every follower.
    assert append_entries_recipients() == [:b, :c]

    # Every heartbeat tick sends to every follower, including followers that
    # answered less than one heartbeat interval before the tick.
    {raft, sent} = tick(raft, 50)
    assert sent == [:b, :c]

    raft = ack(raft, :b, 51)
    raft = ack(raft, :c, 51)

    {_raft, sent} = tick(raft, 100)
    assert sent == [:b, :c]
  end
end
