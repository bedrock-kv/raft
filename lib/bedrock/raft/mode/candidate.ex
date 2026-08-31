defmodule Bedrock.Raft.Mode.Candidate do
  @moduledoc """
  The Candidate state of the RAFT consensus protocol is a critical stage that
  occurs when a peer in the Raft cluster transitions from a Follower to a
  Candidate. This phase is integral to the leader election process in Raft.

  Here are the key aspects of the Candidate phase:

  - Initiation of Election: The Candidate phase begins when a follower doesn't
    receive a heartbeat from a leader within a set timeout period. This
    indicates that the current leader is either down or unreachable, prompting
    the follower to become a candidate.

  - Increment Term and Vote for Self: Upon entering the Candidate phase, the
    peer increments its current term number (a logical clock) and votes for
    itself. This is the start of attempting to become the new leader.

  - Requesting Votes: The candidate then sends out RequestVote RPCs (Remote
    Procedure Calls) to all other peers in the cluster. In these requests, the
    candidate includes its term number and the last log entry it has, which
    helps other peers decide whether to grant their vote to the candidate.

  - Majority Votes: To become a leader, the candidate needs to receive votes
    from a majority (quorum) of the peers in the cluster. This majority is
    essential for ensuring only one leader is elected per term and to maintain
    consistency.

  - Handling Parallel Elections: If multiple followers become candidates
    simultaneously, parallel elections can occur. This might lead to a split
    vote, where no candidate receives the majority. If this happens, a new
    election term begins, and peers will retry the election process.

  - Timeout and Retry: If a candidate does not get a majority of votes within a
    certain timeout period, it will restart the election process. This involves
    incrementing its term and sending out a new round of RequestVote RPCs.

  - Transition to Leader: If the candidate receives the majority of votes, it
    transitions to the Leader phase.

  - Response to External Leader Claim: If, during the candidate phase, a peer
    receives a legitimate AppendEntries RPC from another peer claiming to be
    the leader, and the claimant's term is at least as large as the candidate’s
    current term, the candidate reverts to a follower. This ensures that there
    is only one leader at a time in the cluster.
  """
  @behaviour Bedrock.Raft.Mode

  alias Bedrock.Raft
  alias Bedrock.Raft.Log
  alias Bedrock.Raft.TransactionID

  import Bedrock.Raft.Telemetry,
    only: [
      track_request_votes: 3,
      track_vote_received: 2,
      track_election_ended: 3,
      track_vote_sent: 2
    ]

  @type t :: %__MODULE__{
          term: Raft.election_term(),
          quorum: Raft.quorum(),
          peers: [Raft.peer()],
          votes: [Raft.peer()],
          voted_for: Raft.peer() | nil,
          log: Log.t(),
          interface: module(),
          cancel_timer_fn: function() | nil
        }
  defstruct [
    :term,
    :quorum,
    :peers,
    :votes,
    :voted_for,
    :log,
    :interface,
    :cancel_timer_fn
  ]

  @spec new(
          Raft.election_term(),
          Raft.quorum(),
          [Raft.peer()],
          log :: Log.t(),
          interface :: module()
        ) ::
          t() | :become_leader
  def new(term, quorum, peers, log, interface) do
    %__MODULE__{
      term: term,
      quorum: quorum,
      peers: peers,
      votes: [],
      voted_for: nil,
      log: log,
      interface: interface
    }
    |> request_votes()
    |> become_leader_with_quorum()
    |> case do
      :become_leader ->
        # Return marker for single-node immediate election
        :become_leader

      {:ok, candidate} ->
        # Multi-node cluster, set timer and wait for votes
        candidate |> set_timer()
    end
  end

  @impl true
  @spec vote_requested(
          t(),
          Raft.election_term(),
          candidate :: Raft.peer(),
          candidate_last_transaction_id :: Raft.transaction_id()
        ) :: {:ok, t()} | :become_follower
  def vote_requested(t, term, candidate, candidate_newest_transaction_id)
      when term >= t.term and is_nil(t.voted_for) do
    if log_at_least_as_up_to_date?(
         candidate_newest_transaction_id,
         Log.newest_transaction_id(t.log)
       ) do
      t |> vote_for(term, candidate)
    else
      t
    end
    |> then(&{:ok, &1})
  end

  def vote_requested(t, _, _, _), do: {:ok, t}

  @doc """
  A vote has been received. If the voting term is equal to our term, and we
  haven't yet seen a vote from that follower, we record it and then check to
  see if we've received enough votes to win the election.

  If the voting term is larger than our term, then we'll become a follower.

  Otherwise, we just ignore the vote.
  """
  @impl true
  @spec vote_received(t(), Raft.election_term(), follower :: Raft.peer()) ::
          :become_leader | :become_follower | {:ok, t()}
  def vote_received(t, term, follower) when term == t.term do
    track_vote_received(term, follower)
    t |> add_to_votes(follower) |> become_leader_with_quorum()
  end

  def vote_received(t, term, _) when term > t.term, do: t |> become_follower()
  def vote_received(t, _, _), do: {:ok, t}

  @spec add_to_votes(t(), follower :: Raft.peer()) :: t()
  def add_to_votes(t, follower),
    do: if(follower in t.votes, do: t, else: %{t | votes: [follower | t.votes]})

  @spec become_leader_with_quorum(t()) :: {:ok, t()} | :become_leader
  def become_leader_with_quorum(t) when length(t.votes) >= t.quorum, do: t |> become_leader()
  def become_leader_with_quorum(t), do: {:ok, t}

  @doc """
  Since we are not the leader, we cannot add transactions.
  """
  @impl true
  @spec add_transaction(t(), transaction_payload :: term()) :: {:error, :not_leader}
  def add_transaction(_, _), do: {:error, :not_leader}

  @doc """
  An append entries ack has been received. If the term is greater than our
  term, then we will cancel any outstanding timers and signal that a new
  leader has been elected. Otherwise, we'll ignore the it.
  """
  @impl true
  @spec append_entries_ack_received(
          any(),
          Raft.election_term(),
          success :: boolean(),
          request_transaction_id :: Raft.transaction_id(),
          follower :: Raft.peer()
        ) :: {:ok, any()} | :become_follower
  def append_entries_ack_received(t, term, _, _, _) when term > t.term,
    do: become_follower(t)

  def append_entries_ack_received(t, _, _, _, _), do: {:ok, t}

  @doc """
  A ping has been received. If the term is greater than or equal to our term,
  then we will cancel any outstanding timers and signal that a new leader has
  been elected. Otherwise, we'll ignore the it.
  """
  @impl true
  @spec append_entries_received(
          t(),
          term :: Raft.election_term(),
          prev_transaction_id :: Raft.transaction_id(),
          transactions :: [Raft.transaction()],
          commit_transaction_id :: Raft.transaction_id(),
          from :: Raft.peer()
        ) ::
          {:ok, t()} | :become_follower
  def append_entries_received(t, term, _, _, _, _) when term >= t.term, do: become_follower(t)
  def append_entries_received(t, _, _, _, _, _), do: {:ok, t}

  @impl true
  @spec timer_ticked(t(), :election) :: {:ok, t()}
  def timer_ticked(t, :election) do
    track_election_ended(t.term, t.votes, t.quorum)

    t
    |> clear_votes()
    |> set_timer()
    |> request_votes()
    |> then(&{:ok, &1})
  end

  def timer_ticked(t, _), do: {:ok, t}

  @spec become_follower(t()) :: :become_follower
  def become_follower(t) do
    t |> cancel_timer()
    :become_follower
  end

  @spec become_leader(t()) :: :become_leader
  def become_leader(t) do
    t |> cancel_timer()
    :become_leader
  end

  defp clear_votes(t), do: %{t | votes: []}

  @spec vote_for(t(), Raft.election_term(), Raft.peer()) :: t()
  defp vote_for(t, term, candidate) do
    track_vote_sent(term, candidate)
    t.interface.send_event(candidate, {:vote, term})
    %{t | voted_for: candidate, term: term}
  end

  @spec request_votes(t()) :: t()
  defp request_votes(t) do
    my_newest_txn_id = Log.newest_transaction_id(t.log)
    track_request_votes(t.term, t.peers, my_newest_txn_id)
    event = {:request_vote, t.term, my_newest_txn_id}
    t.peers |> Enum.each(&t.interface.send_event(&1, event))
    t
  end

  @spec cancel_timer(t()) :: t()
  defp cancel_timer(t) when is_nil(t.cancel_timer_fn), do: t

  defp cancel_timer(t) do
    t.cancel_timer_fn.()
    %{t | cancel_timer_fn: nil}
  end

  @spec set_timer(t()) :: t()
  defp set_timer(t), do: %{t | cancel_timer_fn: t.interface.timer(:election)}

  # Raft log safety check: candidate is at least as up-to-date (term priority, then index)
  @spec log_at_least_as_up_to_date?(Raft.transaction_id(), Raft.transaction_id()) :: boolean()
  defp log_at_least_as_up_to_date?(candidate_txn_id, my_txn_id) do
    candidate_term = TransactionID.term(candidate_txn_id)
    my_term = TransactionID.term(my_txn_id)

    cond do
      candidate_term > my_term -> true
      candidate_term < my_term -> false
      true -> TransactionID.index(candidate_txn_id) >= TransactionID.index(my_txn_id)
    end
  end
end
