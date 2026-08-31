defmodule Bedrock.Raft.Mode.Follower do
  @moduledoc """
  The Follower state of the RAFT protocol. This is the state that a peer is in
  when it is not the leader, and is waiting for a leader to emerge, but has not
  yet decided to stand as a candidate for election itself.

  These are the key characteristics of this phase:

  - Passivity: Followers are mostly passive. They don't issue requests on
    their own but respond to requests from leaders and candidates.

  - Responding to Leaders: When a follower receives a heartbeat (a signal to
    prevent election timeouts) or data from the current leader, it updates its
    internal state and then responds to the leader’s requests.

  - Election Timeout: Each follower has an election timeout. If a follower
    doesn't hear from a leader before this timeout, it assumes there is no
    current leader and indicates that a transition to the Candidate state is
    necessary to start an election.

  - Log Replication: Followers receive log entries from the leader. They append
    these entries to their log and return acknowledgment to the leader.

  - Committing Entries: Once a log entry is safely replicated, the leader
    informs the followers to commit the entry. The followers then apply the
    entry to their local state machines.

  - Consistency Check: If there's a discrepancy in the log entries between a
    leader and a follower, the follower rejects the new entries. The leader
    then works to bring the follower's log into consistency with its own.
  """
  @behaviour Bedrock.Raft.Mode

  alias Bedrock.Raft
  alias Bedrock.Raft.Log
  alias Bedrock.Raft.TransactionID

  import Bedrock.Raft.Telemetry,
    only: [
      track_leadership_change: 2,
      track_consensus_reached: 1,
      track_vote_sent: 2,
      track_append_entries_received: 5,
      track_append_entries_ack_sent: 4
    ]

  @type t :: %__MODULE__{
          me: Raft.peer(),
          term: Raft.election_term(),
          leader: Raft.peer() | :undecided,
          voted_for: Raft.peer() | nil,
          cancel_timer_fn: function() | nil,
          log: Log.t(),
          interface: module()
        }
  defstruct ~w[
      me
      term
      leader
      voted_for
      cancel_timer_fn
      log
      interface
    ]a

  @spec new(
          Raft.election_term(),
          Log.t(),
          interface :: module(),
          me :: Raft.peer(),
          leader :: Raft.peer()
        ) :: t()
  def new(term, log, interface, me, leader \\ :undecided) do
    %__MODULE__{
      me: me,
      term: term,
      leader: leader,
      voted_for: Log.voted_for(log),
      log: log,
      interface: interface
    }
    |> set_timer()
  end

  @doc """
  Our vote has been requested by a candidate. We'll vote for the candidate if
  we haven't yet voted in this election, or:
    - the candidate's election term is greater or equal to our term, and
    - the candidate's last transaction is at least as up-to-date as ours.

  Otherwise, we'll ignore the request.
  """
  @impl true
  @spec vote_requested(
          t(),
          Raft.election_term(),
          candidate :: Raft.peer(),
          candidate_last_transaction_id :: Raft.transaction_id()
        ) :: {:ok, t()} | :become_follower
  def vote_requested(t, term, candidate, candidate_newest_transaction_id) when term > t.term do
    t
    |> advance_term(term)
    |> vote_requested(term, candidate, candidate_newest_transaction_id)
  end

  def vote_requested(t, term, candidate, candidate_newest_transaction_id)
      when term == t.term do
    if log_at_least_as_up_to_date?(
         candidate_newest_transaction_id,
         Log.newest_transaction_id(t.log)
       ) and (is_nil(t.voted_for) or t.voted_for == candidate) do
      t
      |> reset_timer()
      |> vote_for(term, candidate)
    else
      t
    end
    |> then(&{:ok, &1})
  end

  def vote_requested(t, _, _, _), do: {:ok, t}

  @doc """
  """
  @impl true
  @spec vote_received(t(), Raft.election_term(), follower :: Raft.peer()) ::
          :become_follower | {:ok, t()}
  def vote_received(t, term, _) when term > t.term, do: become_follower(t)
  def vote_received(t, _, _), do: {:ok, t}

  @doc """
  As a follower, we cannot add transactions. So we don't.
  """
  @impl true
  @spec add_transaction(t(), transaction_payload :: term()) :: {:error, :not_leader}
  def add_transaction(_t, _transaction_payload), do: {:error, :not_leader}

  @doc """
  As a follower, we don't need to do anything when we receive an append entries
  acknowledgement. If the term is greater than our term, then we will cancel
  any outstanding timers and record that a new leader has been elected.
  Otherwise, we'll ignore it.
  """
  @impl true
  @spec append_entries_ack_received(
          t(),
          Raft.election_term(),
          success :: boolean(),
          request_transaction_id :: Raft.transaction_id(),
          follower :: Raft.peer()
        ) :: {:ok, t()} | :become_follower
  def append_entries_ack_received(t, term, _, _, _) when term > t.term,
    do: t |> become_follower()

  def append_entries_ack_received(t, _, _, _, _), do: {:ok, t}

  @doc """
  A ping has been received. If the term is greater than our term, then we will
  cancel any outstanding timers and record that a new leader has been elected.
  Otherwise, we'll ignore it.
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
          {:ok, t()}
  # Accept append_entries from any peer with higher term per Raft specification

  def append_entries_received(
        t,
        term,
        prev_transaction_id,
        transactions,
        commit_transaction_id,
        from
      )
      when term >= t.term do
    t = advance_term(t, term)

    track_append_entries_received(
      term,
      from,
      prev_transaction_id,
      transactions |> Enum.map(&elem(&1, 0)),
      commit_transaction_id
    )

    case validate_log_consistency(t.log, prev_transaction_id) do
      :ok ->
        request_match_transaction_id =
          request_match_transaction_id(prev_transaction_id, transactions)

        t
        |> reset_timer()
        |> note_change_in_leadership_if_necessary(from, term)
        |> try_to_append_transactions(prev_transaction_id, transactions)
        |> case do
          {:ok, t} ->
            t
            |> try_to_reach_consensus(commit_transaction_id, request_match_transaction_id)
            |> send_append_entries_ack(true, request_match_transaction_id)
            |> then(&{:ok, &1})

          {:error, t} ->
            t
            |> send_append_entries_ack(false, prev_transaction_id)
            |> then(&{:ok, &1})
        end

      :invalid ->
        t
        |> reset_timer()
        |> note_change_in_leadership_if_necessary(from, term)
        |> send_append_entries_ack(false, prev_transaction_id)
        |> then(&{:ok, &1})
    end
  end

  def append_entries_received(t, _term, prev_transaction_id, _transactions, _commit, from) do
    send_append_entries_ack(t, from, false, prev_transaction_id)
    {:ok, t}
  end

  defp request_match_transaction_id(prev_transaction_id, []), do: prev_transaction_id

  defp request_match_transaction_id(_prev_transaction_id, transactions) do
    transactions |> List.last() |> elem(0)
  end

  @impl true
  @spec timer_ticked(t(), :election) :: :become_candidate
  def timer_ticked(t, :election), do: t |> become_candidate()
  def timer_ticked(t, _), do: {:ok, t}

  # Validate log consistency per Raft specification
  @spec validate_log_consistency(Log.t(), Raft.transaction_id()) :: :ok | :invalid
  defp validate_log_consistency(log, prev_transaction_id) do
    if prev_transaction_id == Log.initial_transaction_id(log) do
      :ok
    else
      if Log.has_transaction_id?(log, prev_transaction_id) do
        :ok
      else
        :invalid
      end
    end
  end

  def try_to_append_transactions(t, _prev_transaction, []), do: {:ok, t}

  def try_to_append_transactions(t, prev_transaction_id, transactions) do
    existing_transactions = Log.transactions_from(t.log, prev_transaction_id, :newest)

    case reconcile_transactions(existing_transactions, transactions, prev_transaction_id) do
      :unchanged ->
        {:ok, t}

      {:append_after, matching_transaction_id, transactions_to_append} ->
        with {:ok, log} <-
               Log.purge_transactions_after(t.log, matching_transaction_id),
             {:ok, log} <-
               Log.append_transactions(log, matching_transaction_id, transactions_to_append) do
          {:ok, %{t | log: log}}
        else
          {:error, :prev_transaction_not_found} -> {:error, t}
          {:error, :would_delete_committed_transactions} -> {:error, t}
        end
    end
  end

  @spec reconcile_transactions(
          existing_transactions :: [Raft.transaction()],
          incoming_transactions :: [Raft.transaction()],
          last_matching_transaction_id :: Raft.transaction_id()
        ) ::
          :unchanged | {:append_after, Raft.transaction_id(), [Raft.transaction()]}
  defp reconcile_transactions(_existing_transactions, [], _last_matching_transaction_id),
    do: :unchanged

  defp reconcile_transactions([], incoming_transactions, last_matching_transaction_id),
    do: {:append_after, last_matching_transaction_id, incoming_transactions}

  defp reconcile_transactions(
         [{existing_id, _existing_payload} | existing_transactions],
         [{incoming_id, _incoming_payload} | incoming_transactions] = remaining_incoming,
         last_matching_transaction_id
       ) do
    if same_index_and_term?(existing_id, incoming_id) do
      reconcile_transactions(existing_transactions, incoming_transactions, existing_id)
    else
      {:append_after, last_matching_transaction_id, remaining_incoming}
    end
  end

  defp same_index_and_term?(left_id, right_id) do
    TransactionID.index(left_id) == TransactionID.index(right_id) and
      TransactionID.term(left_id) == TransactionID.term(right_id)
  end

  defp note_change_in_leadership_if_necessary(t, leader, term)
       when t.leader == :undecided or term > t.term do
    track_leadership_change(leader, term)
    t.interface.leadership_changed({leader, term})
    %{t | leader: leader, term: term}
  end

  defp note_change_in_leadership_if_necessary(t, _, _), do: t

  defp try_to_reach_consensus(t, leader_commit_transaction_id, request_match_transaction_id) do
    commit_transaction_id =
      if TransactionID.index(leader_commit_transaction_id) <=
           TransactionID.index(request_match_transaction_id) do
        leader_commit_transaction_id
      else
        request_match_transaction_id
      end

    if Log.has_transaction_id?(t.log, commit_transaction_id) do
      commit_transaction(t, commit_transaction_id)
    else
      t
    end
  end

  defp commit_transaction(t, commit_transaction_id) do
    newest_transaction_id = Log.newest_transaction_id(t.log)

    Log.commit_up_to(t.log, commit_transaction_id)
    |> case do
      {:ok, log} ->
        track_consensus_reached(commit_transaction_id)

        consistency =
          if newest_transaction_id == commit_transaction_id do
            :latest
          else
            :behind
          end

        :ok = t.interface.consensus_reached(log, commit_transaction_id, consistency)
        %{t | log: log}

      :unchanged ->
        t
    end
  end

  defp become_follower(t) do
    t |> cancel_timer()
    :become_follower
  end

  defp become_candidate(t) do
    t |> cancel_timer()
    :become_candidate
  end

  @spec send_append_entries_ack(t(), boolean(), Raft.transaction_id()) :: t()
  defp send_append_entries_ack(t, success, request_transaction_id)
       when t.leader != :undecided do
    send_append_entries_ack(t, t.leader, success, request_transaction_id)
  end

  defp send_append_entries_ack(t, _success, _request_transaction_id), do: t

  @spec send_append_entries_ack(t(), Raft.peer(), boolean(), Raft.transaction_id()) :: t()
  defp send_append_entries_ack(t, leader, success, request_transaction_id) do
    track_append_entries_ack_sent(t.term, leader, success, request_transaction_id)

    t.interface.send_event(
      leader,
      {:append_entries_ack, t.term, success, request_transaction_id}
    )

    t
  end

  @spec vote_for(t(), Raft.election_term(), Raft.peer()) :: t()
  defp vote_for(t, term, candidate) do
    {:ok, log} = Log.save_election_state(t.log, term, candidate)
    track_vote_sent(term, candidate)
    t.interface.send_event(candidate, {:vote, term})
    %{t | voted_for: candidate, term: term, log: log}
  end

  defp advance_term(t, term) when term > t.term do
    {:ok, log} = Log.save_election_state(t.log, term, nil)
    %{t | term: term, leader: :undecided, voted_for: nil, log: log}
  end

  defp advance_term(t, _term), do: t

  @spec reset_timer(t()) :: t()
  defp reset_timer(t), do: t |> cancel_timer() |> set_timer()

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
