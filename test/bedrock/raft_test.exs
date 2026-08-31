defmodule Bedrock.RaftTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Bedrock.Raft
  alias Bedrock.Raft.Log
  alias Bedrock.Raft.Log.InMemoryLog
  alias Bedrock.Raft.Mode.Candidate
  alias Bedrock.Raft.Mode.Follower
  alias Bedrock.Raft.Mode.Leader

  import Mox
  alias Bedrock.Raft.MockInterface

  setup [:verify_on_exit!, :fix_stubs, :start_clock]

  def mock_timer_cancel, do: :ok

  defmodule Clock do
    use Agent

    # Starts the agent with the current system time or a custom initial time
    def start_link(opts) do
      initial_time = opts[:initial_time] || 1000

      Agent.start_link(fn -> %{initial_time: initial_time, clocks: %{}} end,
        name: opts[:name] || __MODULE__
      )
    end

    # Gets the current time from the agent
    def timestamp_in_ms(clock), do: Agent.get(__MODULE__, &(&1.clocks[clock] || &1.initial_time))

    # Advances the time by the given amount (e.g., milliseconds)
    def advance_time(clock, milliseconds) do
      Agent.update(
        __MODULE__,
        &update_in(&1, [:clocks, clock], fn time -> (time || &1.initial_time) + milliseconds end)
      )
    end
  end

  def fix_stubs(context) do
    stub(MockInterface, :heartbeat_ms, fn -> 50 end)
    stub(MockInterface, :quorum_lost, fn _active, _total, _term -> :continue end)
    {:ok, context}
  end

  def start_clock(context) do
    start_supervised!(Clock)
    clock_name = :crypto.strong_rand_bytes(3) |> Base.encode32(padding: false)
    stub(MockInterface, :timestamp_in_ms, fn -> Clock.timestamp_in_ms(clock_name) end)
    advance_time = &Clock.advance_time(clock_name, &1)

    {:ok,
     context
     |> Map.merge(%{
       clock_name: clock_name,
       advance_time: advance_time
     })}
  end

  describe "Raft can be constructed" do
    test "when creating an instance with no other peers, we start out as a follower" do
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      p = Raft.new(:a, [], InMemoryLog.new(), MockInterface)

      assert %Raft{
               me: :a,
               mode: %Follower{
                 term: 0,
                 leader: :undecided
               },
               peers: [],
               quorum: 0
             } = p

      assert :a = Raft.me(p)
      assert {:undecided, 0} = Raft.leadership(p)
      refute Raft.am_i_the_leader?(p)
      assert [:a] = Raft.known_peers(p)
    end

    test "when creating an instance with other peers, we start out as a follower" do
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      p = Raft.new(:a, [:b], InMemoryLog.new(), MockInterface)

      assert %Raft{
               me: :a,
               mode: %Follower{
                 term: 0,
                 leader: :undecided,
                 voted_for: nil,
                 cancel_timer_fn: cancel_timer_fn
               },
               peers: [:b],
               quorum: 1
             } = p

      assert cancel_timer_fn == (&mock_timer_cancel/0)

      assert :a = Raft.me(p)
      assert {:undecided, 0} = Raft.leadership(p)
      refute Raft.am_i_the_leader?(p)
      assert [:a, :b] = Raft.known_peers(p)
    end

    test "when creating an instance with more than zero other peers, we start out as a follower" do
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      p = Raft.new(:a, [:b], InMemoryLog.new(), MockInterface)

      assert %Raft{
               me: :a,
               mode: %Follower{
                 term: 0,
                 leader: :undecided,
                 voted_for: nil,
                 cancel_timer_fn: cancel_timer_fn
               },
               peers: [:b],
               quorum: 1
             } = p

      assert cancel_timer_fn == (&mock_timer_cancel/0)

      assert :a = Raft.me(p)
      assert {:undecided, 0} = Raft.leadership(p)
      refute Raft.am_i_the_leader?(p)
      assert [:a, :b] = Raft.known_peers(p)
    end
  end

  describe "Raft elections" do
    test "A happy-path election between three peers that we started", %{
      advance_time: advance_time
    } do
      t0 = {0, 0}

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      p = Raft.new(:a, [:b, :c], InMemoryLog.new(), MockInterface)

      # We haven't yet heard from any other peers, so there's definitely no
      # leader.
      assert {:undecided, 0} = Raft.leadership(p)
      refute Raft.am_i_the_leader?(p)

      # Assuming that peer :a's election timer expires, it will become a
      # candidate and start an election for term 2. It will send a request_vote
      # message to :b and :c.
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:request_vote, 1, ^t0} -> :ok end)

      p = Raft.handle_event(p, :election, :timer)

      assert %Raft{
               me: :a,
               mode: %Candidate{
                 term: 1,
                 quorum: 1,
                 peers: [:b, :c],
                 votes: []
               },
               peers: [:b, :c],
               quorum: 1
             } = p

      # Verify term was incremented and persisted during election
      log = Raft.log(p)
      assert Log.current_term(log) == 1

      # While we are a candidate, there's definitely no leader.
      assert {:undecided, 1} = Raft.leadership(p)
      refute Raft.am_i_the_leader?(p)

      # Assuming that peer :b receives the request_vote message first, it will
      # respond with a vote for term 2. With one vote, we reach the quorum and
      # become leader.
      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {:a, 1} -> :ok end)

      p = Raft.handle_event(p, {:vote, 1}, :b)

      # After we've won the election, we should be the leader.

      verify!()
      assert {:a, 1} = Raft.leadership(p)
      assert Raft.am_i_the_leader?(p)

      assert %Raft{
               me: :a,
               mode: %Leader{
                 peers: [:b, :c],
                 quorum: 1,
                 term: 1
               },
               peers: [:b, :c],
               quorum: 1
             } = p

      # Assuming that peer :c also responds to the request_vote, we've already
      # reached the quorum and become leader. We'll ignore the vote.

      p = Raft.handle_event(p, {:vote, 1}, :c)

      verify!()

      assert %Raft{
               me: :a,
               mode: %Leader{
                 peers: [:b, :c],
                 quorum: 1,
                 term: 1
               },
               peers: [:b, :c],
               quorum: 1
             } = p

      # Assuming that peer :c receives the ping and responds with a pong,
      # ensure that it is recorded properly.
      p = Raft.handle_event(p, {:append_entries_ack, 1, {0, 0}}, :c)

      verify!()

      assert %Raft{
               me: :a,
               mode: %Leader{
                 peers: [:b, :c],
                 quorum: 1,
                 term: 1
               },
               peers: [:b, :c],
               quorum: 1
             } = p

      # At the next heartbeat timer, assuming that peer :c receives the ping and
      # responds with a pong, ensure that it is recorded properly.
      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)

      # Bounce the clock ahead 51ms
      advance_time.(51)

      p = Raft.handle_event(p, :heartbeat, :timer)

      verify!()

      assert %Raft{
               me: :a,
               mode: %Leader{
                 peers: [:b, :c],
                 quorum: 1,
                 term: 1
               },
               peers: [:b, :c],
               quorum: 1
             } = p
    end

    test "A happy-path election between three peers that we vote in" do
      log = InMemoryLog.new()

      t0 = Log.initial_transaction_id(log)

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      p = Raft.new(:a, [:b, :c], log, MockInterface)

      verify!()

      assert %Raft{
               me: :a,
               mode: %Follower{
                 term: 0,
                 leader: :undecided,
                 voted_for: nil
               },
               peers: [:b, :c],
               quorum: 1
             } = p

      # Node :c calls an election for term 1, and sends a request_vote message

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :c, {:vote, 1} -> :ok end)

      p = Raft.handle_event(p, {:request_vote, 1, {0, 1}}, :c)

      verify!()

      assert %Raft{
               me: :a,
               mode: %Follower{
                 term: 1,
                 leader: :undecided,
                 voted_for: :c
               },
               peers: [:b, :c],
               quorum: 1
             } = p

      # Node :c calls to inform that the election has been decided for term 1,
      # and that it has been elected.

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :c, {:append_entries_ack, 1, ^t0} -> :ok end)
      expect(MockInterface, :leadership_changed, fn {:c, 1} -> :ok end)

      p = Raft.handle_event(p, {:append_entries, 1, t0, [], t0}, :c)

      verify!()

      assert %Raft{
               me: :a,
               mode: %Follower{
                 term: 1,
                 leader: :c,
                 voted_for: :c
               },
               peers: [:b, :c],
               quorum: 1
             } = p

      assert {:c, 1} = Raft.leadership(p)
    end

    test "After becoming a candidate, if the election timer expires then a new election is started" do
      t0 = {0, 0}

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      p = Raft.new(:a, [:b, :c], InMemoryLog.new(), MockInterface)

      verify!()

      # Timer elapses the first time, so we start an election for term 1

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:request_vote, 1, ^t0} -> :ok end)

      p = Raft.handle_event(p, :election, :timer)

      verify!()

      assert %Raft{
               me: :a,
               mode: %Candidate{
                 term: 1,
                 quorum: 1,
                 peers: [:b, :c],
                 votes: []
               },
               peers: [:b, :c],
               quorum: 1
             } = p

      # Timer elapses the second time with no votes, so we start a new election
      # in term 2 and persist a fresh self-vote.

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:request_vote, 2, ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:request_vote, 2, ^t0} -> :ok end)

      p = Raft.handle_event(p, :election, :timer)

      verify!()

      assert %Raft{
               me: :a,
               mode: %Candidate{
                 term: 2,
                 quorum: 1,
                 peers: [:b, :c],
                 voted_for: :a,
                 votes: []
               },
               peers: [:b, :c],
               quorum: 1
             } = p

      assert Log.current_term(Raft.log(p)) == 2
      assert Log.voted_for(Raft.log(p)) == :a
    end

    test "In a three peer cluster, as a candidate we receive a vote from a follower in an older term" do
      t0 = {0, 0}

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      p =
        Raft.new(:a, [:b, :c], InMemoryLog.new(), MockInterface)
        |> Raft.handle_event(:election, :timer)

      verify!()
      assert %Raft{mode: %Candidate{}} = p
      assert {:undecided, 1} = Raft.leadership(p)

      # Packets were dropped, :a became separated, an election was held and a
      # new leader, :c, was elected. After the split was healed, :a receives a
      # heartbeat from the new leader in term 3.

      p = p |> Raft.handle_event({:vote, 0}, :c)

      verify!()
      assert {:undecided, 1} = Raft.leadership(p)
    end

    test "In a three peer cluster, as a candidate we receive a ping from a leader in the same term" do
      t0 = {0, 0}

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:request_vote, 1, ^t0} -> :ok end)

      p =
        Raft.new(:a, [:b, :c], InMemoryLog.new(), MockInterface)
        |> Raft.handle_event(:election, :timer)

      verify!()
      assert %Raft{mode: %Candidate{}} = p
      assert {:undecided, 1} = Raft.leadership(p)

      # Packets were dropped, :a became separated, an election was held and a
      # new leader, :c, was elected. After the split was healed, :a receives a
      # heartbeat from the new leader in term 3.

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :c, {:append_entries_ack, 2, ^t0} -> :ok end)
      expect(MockInterface, :leadership_changed, fn {:c, 2} -> :ok end)

      p = p |> Raft.handle_event({:append_entries, 2, t0, [], t0}, :c)

      verify!()
      assert {:c, 2} = Raft.leadership(p)
    end

    test "In a three peer cluster, as a candidate we receive a ping from a leader in an older term" do
      t0 = {0, 0}

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      p =
        Raft.new(:a, [:b, :c], InMemoryLog.new(), MockInterface)
        |> Raft.handle_event(:election, :timer)

      verify!()
      assert %Raft{mode: %Candidate{}} = p
      assert {:undecided, 1} = Raft.leadership(p)

      # Packets were dropped, :a became separated, an election was held and a
      # new leader, :c, was elected. After the split was healed, :a receives a
      # heartbeat from the leader of term 1.

      p = p |> Raft.handle_event({:append_entries, 0, t0, [], t0}, :c)

      verify!()
      assert {:undecided, 1} = Raft.leadership(p)
    end

    test "In a three peer cluster, after winning a successful election during a network split, a new leader was elected with no other missed transactions",
         %{advance_time: advance_time} do
      t0 = {0, 0}
      t1 = {2, 0}

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {:a, 1} -> :ok end)

      p =
        Raft.new(:a, [:b, :c], InMemoryLog.new(), MockInterface)
        |> Raft.handle_event(:election, :timer)
        |> Raft.handle_event({:vote, 1}, :c)
        |> Raft.handle_event({:vote, 1}, :b)
        |> Raft.handle_event({:append_entries_ack, 1, t0}, :c)
        |> Raft.handle_event({:append_entries_ack, 1, t0}, :b)

      verify!()

      advance_time.(51)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)

      p = p |> Raft.handle_event(:heartbeat, :timer)

      verify!()

      assert {:a, 1} = Raft.leadership(p)

      # Packets were dropped, :a became separated, an election was held and a
      # new leader, :c, was elected. After the split was healed, :a receives a
      # heartbeat from the new leader in term 2.

      advance_time.(50)

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :c, {:append_entries_ack, 2, ^t0} -> :ok end)
      expect(MockInterface, :leadership_changed, fn {:c, 2} -> :ok end)

      p = p |> Raft.handle_event({:append_entries, 2, t1, [{t1, :data1}], t1}, :c)

      verify!()
      assert {:c, 2} = Raft.leadership(p)
    end

    test "In a three peer cluster, after winning a successful election during a network split, a new leader was elected with new transactions that we missed",
         %{advance_time: advance_time} do
      log = InMemoryLog.new(:tuple)

      t0 = Log.initial_transaction_id(log)

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {:a, 1} -> :ok end)

      p =
        Raft.new(:a, [:b, :c], log, MockInterface)
        |> Raft.handle_event(:election, :timer)
        |> Raft.handle_event({:vote, 1}, :c)
        |> Raft.handle_event({:vote, 1}, :b)

      verify!()
      assert {:a, 1} = Raft.leadership(p)

      # Packets were dropped, :a became separated, an election was held and a
      # new leader, :c, was elected. After the split was healed, :a receives a
      # heartbeat from the new leader in term 2, but is missing transactions.
      # :a will request the missing transactions from the new leader.

      advance_time.(50)

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :c, {:append_entries_ack, 2, ^t0} -> :ok end)
      expect(MockInterface, :leadership_changed, fn {:c, 2} -> :ok end)

      {:ok, p, t1} = Raft.next_transaction_id(p)
      {:ok, p, t2} = Raft.next_transaction_id(p)
      p = p |> Raft.handle_event({:append_entries, 2, t1, [{t2, :data1}], t1}, :c)

      verify!()

      # When :c sends the missing transactions, we add them to our log and note
      # that fact by sending an ack. We reset our heartbeat timer. Since
      # we've received all the transactions up to t1, we can now signal
      # consensus up to that point.

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :consensus_reached, fn _, ^t1, :behind -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:append_entries_ack, 2, ^t2} -> :ok end)
      p = p |> Raft.handle_event({:append_entries, 2, t0, [{t0, :data1}, {t2, :data1}], t1}, :c)

      verify!()

      # When :c receives the ack, it will send us a new append entries message
      # (that in this case, does not contain any new transactions) that tells
      # us that consensus has been reached up to t2. We will reset our heartbeat
      # timer and signal consensus up to t2.

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :consensus_reached, fn _, ^t2, :latest -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:append_entries_ack, 2, ^t2} -> :ok end)
      p = p |> Raft.handle_event({:append_entries, 2, t2, [], t2}, :c)

      verify!()
      assert {:c, 2} = Raft.leadership(p)
    end
  end

  describe "Raft quorum failures" do
    test "A three peer cluster where we are the leader, and quorum fails", %{
      advance_time: advance_time
    } do
      log = InMemoryLog.new()

      t0 = Log.initial_transaction_id(log)

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {:a, 1} -> :ok end)

      p =
        Raft.new(:a, [:b, :c], log, MockInterface)
        |> Raft.handle_event(:election, :timer)
        |> Raft.handle_event({:vote, 1}, :c)
        |> Raft.handle_event({:vote, 1}, :b)

      verify!()

      assert %Raft{
               me: :a,
               mode: %Leader{
                 peers: [:b, :c],
                 quorum: 1,
                 term: 1
               },
               peers: [:b, :c],
               quorum: 1
             } = p

      assert {:a, 1} = Raft.leadership(p)

      # some time goes by, and we don't hear back from either :b or :c...
      advance_time.(51)

      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)

      p = p |> Raft.handle_event(:heartbeat, :timer)

      verify!()

      # some time goes by, and we don't hear back from either :b or :c...
      advance_time.(50)

      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)

      p = p |> Raft.handle_event(:heartbeat, :timer)

      verify!()

      # some time goes by, and we don't hear back from either :b or :c...
      advance_time.(50)

      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)

      # Bounce the clock ahead 50ms
      advance_time.(50)

      p = p |> Raft.handle_event(:heartbeat, :timer)

      verify!()

      # enough time for followers to be considered inactive
      advance_time.(250)

      expect(MockInterface, :quorum_lost, fn 0, 2, 1 -> :step_down end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {:undecided, 1} -> :ok end)

      p = p |> Raft.handle_event(:heartbeat, :timer)

      verify!()

      refute p |> Raft.am_i_the_leader?()
    end
  end

  describe "Raft log interaction" do
    test "A three peer cluster where we become the leader, and then we append an entry", %{
      advance_time: advance_time
    } do
      log = InMemoryLog.new()

      t0 = Log.initial_transaction_id(log)

      # We start off as a follower. Our election timer expires and we start an
      # election for term 1. We send a request_vote message to :b and :c.

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:request_vote, 1, ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:request_vote, 1, ^t0} -> :ok end)

      p =
        Raft.new(:a, [:b, :c], log, MockInterface)
        |> Raft.handle_event(:election, :timer)

      verify!()
      refute p |> Raft.am_i_the_leader?()

      # We receive a vote from :b and :c, and we become the leader. We send an
      # append_entries message to :b and :c.

      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {:a, 1} -> :ok end)

      p =
        p
        |> Raft.handle_event({:vote, 1}, :c)
        |> Raft.handle_event({:vote, 1}, :b)

      verify!()
      assert p |> Raft.am_i_the_leader?()

      # Some time goes by, and we don't hear back from either :b or :c. Our
      # heartbeat timer expires, and we send out a heartbeat to :b and :c.
      advance_time.(51)

      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :b, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:append_entries, 1, ^t0, [], ^t0} -> :ok end)

      p = p |> Raft.handle_event(:heartbeat, :timer)

      verify!()

      # We receive an ack from :b and :c, for t0 and we reset our heartbeat timer.

      p =
        p
        |> Raft.handle_event({:append_entries_ack, 1, t0}, :b)
        |> Raft.handle_event({:append_entries_ack, 1, t0}, :c)

      verify!()
      assert p |> Raft.am_i_the_leader?()

      # We add a transaction (t1) to our log, and send it to :b and :c.

      expect(MockInterface, :send_event, fn :b, {:append_entries, 1, ^t0, [{t1, :data1}], ^t0} ->
        send(self(), t1)
        :ok
      end)

      expect(MockInterface, :send_event, fn :c, {:append_entries, 1, ^t0, [{t1, :data1}], ^t0} ->
        send(self(), t1)
        :ok
      end)

      assert {:ok, p, t1} = Raft.add_transaction(p, :data1)
      verify!()
      assert_receive ^t1
      assert_receive ^t1

      # We add another transaction (t2) to our log, and send it to :b and :c.

      expect(MockInterface, :send_event, fn :b, {:append_entries, 1, ^t1, [{t2, :data2}], ^t0} ->
        send(self(), t2)
        :ok
      end)

      expect(MockInterface, :send_event, fn :c, {:append_entries, 1, ^t1, [{t2, :data2}], ^t0} ->
        send(self(), t2)
        :ok
      end)

      assert {:ok, p, t2} = Raft.add_transaction(p, :data2)
      verify!()
      assert_receive ^t2
      assert_receive ^t2

      # Our heartbeat timer expires, and we send out a heartbeat to :b and :c.
      # We note that the newest committed transaction is still t0

      # Bounce the clock ahead 51ms
      advance_time.(51)

      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)

      expect(MockInterface, :send_event, fn :b, {:append_entries, 1, ^t2, [], ^t0} ->
        :ok
      end)

      expect(MockInterface, :send_event, fn :c, {:append_entries, 1, ^t2, [], ^t0} ->
        :ok
      end)

      p = p |> Raft.handle_event(:heartbeat, :timer)

      verify!()
      assert [{t1, :data1}, {t2, :data2}] == p |> Raft.log() |> Log.transactions_from(t0, :newest)
      assert t2 == p |> Raft.log() |> Log.newest_transaction_id()
      assert t0 == p |> Raft.log() |> Log.newest_safe_transaction_id()

      # :b acknowledges the heartbeat saying that it has received up to t2, and
      # we make a note of that. since we *also* have a copy of t2, two peers
      # constitutes a quorum and we can decide that consensus has been reached
      # up to t2. we then send out a new heartbeat to both :b and :c to let them
      # know that consensus has been reached up to t2.

      expect(MockInterface, :consensus_reached, fn _, ^t2, :latest -> :ok end)
      expect(MockInterface, :send_event, fn :b, {:append_entries, 1, ^t2, [], ^t2} -> :ok end)
      expect(MockInterface, :send_event, fn :c, {:append_entries, 1, ^t2, [], ^t2} -> :ok end)

      p = p |> Raft.handle_event({:append_entries_ack, 1, t2}, :b)

      verify!()
      assert t2 == p |> Raft.log() |> Log.newest_transaction_id()
      assert t2 == p |> Raft.log() |> Log.newest_safe_transaction_id()

      # :c now acknowledges the heartbeat saying that it has received up to t2
      # as well, and we make a note of that.

      p = p |> Raft.handle_event({:append_entries_ack, 1, t2}, :c)

      verify!()
      assert t2 == p |> Raft.log() |> Log.newest_transaction_id()
      assert t2 == p |> Raft.log() |> Log.newest_safe_transaction_id()
    end

    test "A three peer cluster where we are a follower, where we start off at nothing and need to catch up" do
      log = InMemoryLog.new()
      t0 = Log.initial_transaction_id(log)

      t1 = {2, 0}
      t2 = {2, 1}

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      p = Raft.new(:a, [:b, :c], log, MockInterface)

      verify!()

      # some time passes, and we hear a from an active leader, trying to get us
      # to append past the transactions we have in our log. we'll need to reply
      # with the latest transaction we have.

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :c, {:append_entries_ack, 2, ^t0} -> :ok end)
      expect(MockInterface, :leadership_changed, fn {:c, 2} -> :ok end)

      p = p |> Raft.handle_event({:append_entries, 2, t1, [{t2, :data1}], t1}, :c)

      verify!()

      # the leader responds with a new set of transactions, beginning where we
      # left off, and we append them to our log. we also acknowledge the leader.
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, fn :c, {:append_entries_ack, 2, ^t2} -> :ok end)
      expect(MockInterface, :consensus_reached, fn _, ^t2, :latest -> :ok end)

      p = p |> Raft.handle_event({:append_entries, 2, t0, [{t1, :data1}, {t2, :data2}], t2}, :c)

      verify!()

      # we should have the transactions in our log, and the latest transaction
      # should be the one we just appended. the latest safe transaction should
      # be the one we just appended as well.
      assert [{t1, :data1}, {t2, :data2}] == p |> Raft.log() |> Log.transactions_from(t0, :newest)
      assert t2 == p |> Raft.log() |> Log.newest_transaction_id()
      assert t2 == p |> Raft.log() |> Log.newest_safe_transaction_id()
    end
  end

  describe "Single-node consensus" do
    test "single-node cluster immediately reaches consensus when adding transactions" do
      # Single-node clusters now start as followers and go through election process
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      # Create single-node cluster (no peers) - starts as follower
      raft = Raft.new(:a, [], InMemoryLog.new(), MockInterface)

      # Verify it starts as follower
      refute Raft.am_i_the_leader?(raft)
      assert {:undecided, 0} == Raft.leadership(raft)

      # Simulate election timeout - becomes candidate then leader
      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {:a, 1} -> :ok end)

      raft = Raft.handle_event(raft, :election, :timer)

      # Now it should be leader in term 1
      assert Raft.am_i_the_leader?(raft)
      assert {:a, 1} == Raft.leadership(raft)

      # Add first transaction - should immediately reach consensus (now in term 1)
      expect(MockInterface, :consensus_reached, fn log, {1, 1}, :latest ->
        assert log != nil
        :ok
      end)

      {:ok, raft, txn_id1} = Raft.add_transaction(raft, "first_transaction")
      assert txn_id1 == {1, 1}

      # Verify consensus was reached and term is persisted
      log = Raft.log(raft)
      assert Log.newest_transaction_id(log) == {1, 1}
      assert Log.newest_safe_transaction_id(log) == {1, 1}
      # Term persisted in log (now term 1)
      assert Log.current_term(log) == 1

      # Add second transaction - should also immediately reach consensus
      expect(MockInterface, :consensus_reached, fn _, {1, 2}, :latest -> :ok end)

      {:ok, raft, txn_id2} = Raft.add_transaction(raft, "second_transaction")
      assert txn_id2 == {1, 2}

      # Verify both transactions are committed
      log = Raft.log(raft)
      assert Log.newest_transaction_id(log) == {1, 2}
      assert Log.newest_safe_transaction_id(log) == {1, 2}

      # Verify log contains both transactions
      transactions = Log.transactions_from(log, {0, 0}, :newest)
      assert length(transactions) == 2
      assert transactions == [{{1, 1}, "first_transaction"}, {{1, 2}, "second_transaction"}]
    end

    test "single-node cluster consensus works with different term numbers" do
      # Start as follower
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      # Create single-node cluster - starts as follower
      raft = Raft.new(:single, [], InMemoryLog.new(), MockInterface)

      # Simulate being in term 5 by going through election and updating term
      log = Raft.log(raft)
      {:ok, updated_log} = Log.save_current_term(log, 5)

      # Simulate election process to term 5 leader (without leadership_changed
      # expectation since we're manually creating)
      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)

      # Manually create leader mode in term 5 (simulating election outcome)
      leader_mode = Leader.new(5, 0, [], updated_log, MockInterface)
      raft = %{raft | mode: leader_mode}

      # Add transaction in term 5
      expect(MockInterface, :consensus_reached, fn _, {5, 1}, :latest -> :ok end)

      {:ok, raft, txn_id} = Raft.add_transaction(raft, "high_term_data")
      assert txn_id == {5, 1}

      log = Raft.log(raft)
      assert Log.newest_safe_transaction_id(log) == {5, 1}
      # Verify term persistence
      assert Log.current_term(log) == 5
    end

    test "single-node cluster handles rapid sequential transactions" do
      # Start as follower
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      raft = Raft.new(:rapid, [], InMemoryLog.new(), MockInterface)

      # Go through election to become leader
      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {:rapid, 1} -> :ok end)

      raft = Raft.handle_event(raft, :election, :timer)

      # Rapidly add 5 transactions
      transactions_data = ["txn1", "txn2", "txn3", "txn4", "txn5"]

      {final_raft, txn_ids} =
        transactions_data
        |> Enum.with_index(1)
        |> Enum.reduce({raft, []}, fn {data, index}, {current_raft, ids} ->
          expect(MockInterface, :consensus_reached, fn _, {1, ^index}, :latest -> :ok end)
          {:ok, new_raft, txn_id} = Raft.add_transaction(current_raft, data)
          {new_raft, [txn_id | ids]}
        end)

      # Verify all transactions have correct IDs (now in term 1)
      expected_ids = [{1, 1}, {1, 2}, {1, 3}, {1, 4}, {1, 5}]
      assert Enum.reverse(txn_ids) == expected_ids

      # Verify final state
      log = Raft.log(final_raft)
      assert Log.newest_transaction_id(log) == {1, 5}
      assert Log.newest_safe_transaction_id(log) == {1, 5}

      # Verify all transactions are in log
      all_transactions = Log.transactions_from(log, {0, 0}, :newest)
      assert length(all_transactions) == 5

      expected_transactions = [
        {{1, 1}, "txn1"},
        {{1, 2}, "txn2"},
        {{1, 3}, "txn3"},
        {{1, 4}, "txn4"},
        {{1, 5}, "txn5"}
      ]

      assert all_transactions == expected_transactions
    end
  end

  describe "Error cases and edge paths" do
    test "next_transaction_id returns error when not leader" do
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      p = Raft.new(:a, [:b, :c], InMemoryLog.new(), MockInterface)

      assert {:error, :not_leader} = Raft.next_transaction_id(p)
    end

    test "candidate becomes a follower and votes for a higher-term requester" do
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, 2, fn _, _ -> :ok end)

      candidate =
        Raft.new(:a, [:b, :c], InMemoryLog.new(), MockInterface)
        |> Raft.handle_event(:election, :timer)

      expect(MockInterface, :send_event, fn :peer_d, {:vote, 2} -> :ok end)
      expect(MockInterface, :timer, 2, fn :election -> &mock_timer_cancel/0 end)

      p = Raft.handle_event(candidate, {:request_vote, 2, {1, 1}}, :peer_d)

      assert %Raft{mode: %Follower{term: 2, voted_for: :peer_d}} = p
      assert Log.current_term(Raft.log(p)) == 2
      assert Log.voted_for(Raft.log(p)) == :peer_d
    end

    test "candidate becomes follower on higher term vote" do
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, 2, fn _, _ -> :ok end)

      candidate =
        Raft.new(:a, [:b, :c], InMemoryLog.new(), MockInterface)
        |> Raft.handle_event(:election, :timer)

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)

      p = Raft.handle_event(candidate, {:vote, 2}, :peer_d)

      assert %Raft{mode: %Follower{term: 2}} = p

      # Verify higher term was persisted when becoming follower
      log = Raft.log(p)
      assert Log.current_term(log) == 2
    end

    test "leader becomes follower on higher term ack" do
      log = InMemoryLog.new()
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :send_event, 2, fn _, _ -> :ok end)

      expect(MockInterface, :timer, fn :heartbeat -> &mock_timer_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {:a, 1} -> :ok end)

      leader =
        Raft.new(:a, [:b, :c], log, MockInterface)
        |> Raft.handle_event(:election, :timer)
        |> Raft.handle_event({:vote, 1}, :b)
        |> Raft.handle_event({:vote, 1}, :c)

      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      expect(MockInterface, :leadership_changed, fn {:undecided, 2} -> :ok end)

      p = Raft.handle_event(leader, {:append_entries_ack, 2, {1, 1}}, :peer_d)

      assert %Raft{mode: %Follower{term: 2, leader: :undecided}} = p
    end

    test "unknown events are ignored" do
      expect(MockInterface, :timer, fn :election -> &mock_timer_cancel/0 end)
      p = Raft.new(:a, [:b, :c], InMemoryLog.new(), MockInterface)

      expect(MockInterface, :ignored_event, fn :unknown_event, :peer_x -> :ok end)

      result = Raft.handle_event(p, :unknown_event, :peer_x)

      assert result == p
    end
  end
end
