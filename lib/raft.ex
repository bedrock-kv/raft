defmodule Bedrock.Raft do
  @moduledoc """
  The RAFT consensus protocol. This module implements the state machine for the
  protocol. Externalities like timers and message transport are left as details
  to the user of this module, so as not to tie it to any particular set of
  mechanisms and allow it to be used in a variety of contexts.

  This module is intended to be used as a component of a larger application.

  References:
    - https://raft.github.io/
    - https://arorashu.github.io/posts/raft.html
    - https://www.alibabacloud.com/blog/raft-engineering-practices-and-the-cluster-membership-change_597742
    - http://thesecretlivesofdata.com/raft/
  """

  @type election_term :: non_neg_integer()
  @type index :: non_neg_integer()
  @type quorum :: non_neg_integer()
  @type peer :: atom() | pid() | {atom(), peer()}
  @type leadership :: {leader :: :undecided | peer(), election_term()}
  @type binary_transaction_id :: binary()
  @type tuple_transaction_id :: {term :: election_term(), index :: non_neg_integer()}
  @type transaction_id :: binary_transaction_id() | tuple_transaction_id()
  @type transaction :: {transaction_id(), term()}

  alias Bedrock.Raft
  alias Bedrock.Raft.Log
  alias Bedrock.Raft.Mode.Candidate
  alias Bedrock.Raft.Mode.Follower
  alias Bedrock.Raft.Mode.Leader

  import Bedrock.Raft.Telemetry,
    only: [
      track_became_follower: 2,
      track_became_candidate: 3,
      track_became_leader: 3,
      track_leadership_change: 2,
      track_ignored_event: 2
    ]

  @type t :: %__MODULE__{
          me: peer(),
          mode: Follower.t() | Candidate.t() | Leader.t() | nil,
          peers: [peer()],
          quorum: pos_integer(),
          interface: module()
        }
  defstruct ~w[
      me
      mode
      peers
      quorum
      interface
    ]a

  @doc """
  Create a new RAFT consensus protocol instance.
  """
  @spec new(
          me :: peer(),
          peers :: [peer()],
          log :: Log.t(),
          interface :: module()
        ) :: t()
  def new(me, peers, log, interface) do
    # Assume that we'll always vote for ourselves, so majority - 1.
    quorum = determine_majority([me | peers]) - 1

    # Restore the current term from persistent storage as required by Raft spec.
    term = Log.current_term(log)

    %__MODULE__{
      me: me,
      peers: peers,
      quorum: quorum,
      interface: interface
    }
    |> then(fn t ->
      # All nodes start as followers and must go through election process
      # This ensures Raft specification compliance for term advancement
      t |> become_follower(:undecided, term, log)
    end)
  end

  @doc """
  Return the log for this protocol instance.
  """
  @spec log(t()) :: Log.t()
  def log(t), do: t.mode.log

  @doc """
  Return a new transaction ID for this protocol instance.
  """
  @spec next_transaction_id(t()) :: {:ok, t(), transaction_id()} | {:error, :not_leader}
  def next_transaction_id(%{mode: %Leader{} = leader} = t) do
    leader
    |> Leader.next_id()
    |> then(fn {:ok, leader, txn_id} -> {:ok, %{t | mode: leader}, txn_id} end)
  end

  def next_transaction_id(_t), do: {:error, :not_leader}

  @doc """
  Return the peer that this protocol instance is running on.
  """
  @spec me(t()) :: peer()
  def me(%{me: me}), do: me

  @doc """
  Return true if this peer is the leader of the cluster.
  """
  @spec am_i_the_leader?(t()) :: boolean()
  def am_i_the_leader?(%{mode: %Leader{}}), do: true
  def am_i_the_leader?(_t), do: false

  @doc """
  Return the current leader of the cluster, if any.
  """
  @spec leader(t()) :: peer() | :undecided
  def leader(%{mode: %Follower{}} = t), do: t.mode.leader
  def leader(%{mode: %Leader{}} = t), do: t.me
  def leader(%{mode: %Candidate{}}), do: :undecided
  def leader(%{mode: nil}), do: :undecided

  @doc """
  Return the current term of the cluster.
  """
  @spec term(t()) :: Raft.election_term()
  def term(%{mode: %mode{}} = t)
      when mode in [Follower, Candidate, Leader],
      do: t.mode.term

  @doc """
  Return the current leader and term for the cluster.
  """
  @spec leadership(t()) :: Raft.leadership()
  def leadership(t), do: {leader(t), term(t)}

  @doc """
  Return the peers in the cluster, including ourselves.
  """
  @spec known_peers(t()) :: [peer()]
  def known_peers(t), do: [t.me | t.peers]

  @doc """
  Add a transaction to the log. This is the only way to add transactions to the
  log. Transactions are not committed until the leader replicates them to a
  quorum of peers. Transactions can only be submitted to the leader.
  """
  @spec add_transaction(t(), transaction_payload :: any()) ::
          {:ok, t(), transaction_id()} | {:error, :not_leader}
  def add_transaction(%{mode: %mode{}} = t, transaction_payload) do
    mode.add_transaction(t.mode, transaction_payload)
    |> case do
      {:ok, %Leader{} = mode, txn_id} ->
        {:ok, %{t | mode: mode}, txn_id}

      error ->
        error
    end
  end

  @doc """
  Handle an event from outside the protocol. Timers, messages, etc. This is
  where the work gets done. Events can come from other peers or from a timer.
  """
  @spec handle_event(t(), event :: any(), source :: peer() | :timer) :: t()
  def handle_event(%{mode: %mode{}} = t, name, :timer) do
    mode.timer_ticked(t.mode, name)
    |> case do
      :become_candidate -> t |> become_candidate(next_term(t), log(t))
      :become_follower -> t |> become_follower(:undecided, term(t), log(t))
      {:ok, mode} -> %{t | mode: mode}
    end
  end

  def handle_event(
        %{mode: %{term: current_term}} = t,
        {:request_vote, incoming_term, _} = event,
        from
      )
      when incoming_term > current_term do
    t
    |> transition_to_higher_term(:undecided, incoming_term)
    |> handle_event(event, from)
  end

  def handle_event(
        %{mode: %{term: current_term}} = t,
        {:append_entries, incoming_term, _, _, _} = event,
        from
      )
      when incoming_term > current_term do
    t
    |> transition_to_higher_term(from, incoming_term)
    |> handle_event(event, from)
  end

  def handle_event(%{mode: %{term: current_term}} = t, {:vote, incoming_term}, _from)
      when incoming_term > current_term,
      do: transition_to_higher_term(t, :undecided, incoming_term)

  def handle_event(
        %{mode: %{term: current_term}} = t,
        {:append_entries_ack, incoming_term, _},
        _from
      )
      when incoming_term > current_term,
      do: transition_to_higher_term(t, :undecided, incoming_term)

  def handle_event(%{mode: %mode{}} = t, {:request_vote, term, newest_transaction_id}, candidate) do
    mode.vote_requested(t.mode, term, candidate, newest_transaction_id)
    |> case do
      :become_follower -> t |> become_follower(:undecided, term, log(t))
      {:ok, mode} -> %{t | mode: mode}
    end
  end

  def handle_event(%{mode: %mode{}} = t, {:vote, term}, from) do
    mode.vote_received(t.mode, term, from)
    |> case do
      :become_leader -> t |> become_leader(term, log(t))
      :become_follower -> t |> become_follower(:undecided, term, log(t))
      {:ok, mode} -> %{t | mode: mode}
    end
  end

  def handle_event(
        %{mode: %mode{}} = t,
        {:append_entries, term, prev_transaction_id, transactions, commit_transaction_id} = event,
        from
      ) do
    mode.append_entries_received(
      t.mode,
      term,
      prev_transaction_id,
      transactions,
      commit_transaction_id,
      from
    )
    |> case do
      :become_follower ->
        t |> become_follower(from, term, log(t)) |> handle_event(event, from)

      {:ok, mode} ->
        %{t | mode: mode}
    end
  end

  def handle_event(%{mode: %mode{}} = t, {:append_entries_ack, term, newest_transaction}, from) do
    mode.append_entries_ack_received(t.mode, term, newest_transaction, from)
    |> case do
      :become_follower ->
        t |> become_follower(from, term, log(t))

      {:ok, mode} ->
        %{t | mode: mode}
    end
  end

  def handle_event(t, event, from) do
    track_ignored_event(event, from)
    t.interface.ignored_event(event, from)
    t
  end

  defp become_candidate(t, term, log) do
    track_became_candidate(term, t.quorum, t.peers)

    # Persist both the new term and self-vote before requesting any votes.
    {:ok, updated_log} = Log.save_election_state(log, term, t.me)

    case Candidate.new(t.me, term, t.quorum, t.peers, updated_log, t.interface) do
      :become_leader ->
        # Single-node cluster immediately becomes leader
        t |> become_leader(term, updated_log)

      candidate ->
        # Multi-node cluster becomes candidate and waits for votes
        %{t | mode: candidate}
        |> notify_change_in_leadership(leader(t))
    end
  end

  defp become_follower(t, leader, term, log) do
    track_became_follower(term, leader)

    # Persist the new term if it's higher than our current term (Raft safety requirement)
    updated_log =
      if term > Log.current_term(log) do
        {:ok, log_with_term} = Log.save_election_state(log, term, nil)
        log_with_term
      else
        log
      end

    %{t | mode: Follower.new(term, updated_log, t.interface, t.me, leader)}
    |> notify_change_in_leadership(leader(t))
  end

  defp transition_to_higher_term(%{mode: %Follower{} = follower} = t, leader, term) do
    old_leader = leader(t)
    {:ok, log} = Log.save_election_state(follower.log, term, nil)

    %{t | mode: %{follower | leader: leader, term: term, voted_for: nil, log: log}}
    |> notify_change_in_leadership(old_leader)
  end

  defp transition_to_higher_term(t, leader, term),
    do: become_follower(t, leader, term, log(t))

  defp become_leader(t, term, log) do
    track_became_leader(term, t.quorum, t.peers)

    %{t | mode: Leader.new(term, t.quorum, t.peers, log, t.interface)}
    |> notify_change_in_leadership(leader(t))
  end

  @spec next_term(t()) :: Raft.election_term()
  defp next_term(t), do: 1 + term(t)

  @spec determine_majority([peer()]) :: non_neg_integer()
  defp determine_majority(peers), do: 1 + (peers |> length() |> div(2))

  @spec notify_change_in_leadership(t(), old_leader :: Raft.peer()) :: t()
  defp notify_change_in_leadership(t, old_leader) do
    current_leader = leader(t)

    if current_leader != old_leader do
      current_term = term(t)
      t.interface.leadership_changed({current_leader, current_term})
      track_leadership_change(current_leader, current_term)
    end

    t
  end
end
