defmodule Bedrock.Raft.Mode.Leader do
  @moduledoc """
  The Leader phase in the Raft Consensus Protocol is a crucial stage where a
  peer assumes the role of a leader in the Raft cluster. Once a peer becomes a
  leader, it is responsible for managing the replicated log and ensuring
  consistency across the cluster.

  Here are the key aspects of the Leader phase:

  - Assumption of Leadership: After a peer wins an election during the
    Candidate phase by receiving the majority of votes, it transitions to the
    Leader phase. It assumes authority and starts to manage the cluster's log
    replication.

  - Sending Heartbeats: One of the first actions of the leader is to send out
    heartbeat messages (using AppendEntries RPCs with no log entries) to all
    follower peers. These heartbeats serve two purposes: they inform followers
    that there is a stable leader, and they prevent new elections from being
    triggered.

  - Log Replication: The leader receives client requests, each containing a
    command to be executed by the replicated state machines. The leader appends
    these commands as new entries in its log and then replicates these entries
    to the follower peers.

  - Handling Log Consistency: The leader must ensure that the followers' logs
    are consistent with its own. It does this by checking the consistency of
    the logs with each follower. If there's a mismatch, the leader will resend
    missing or conflicting entries to bring the followers' logs into alignment
    with its own.

  - Committing Entries: After successfully replicating a log entry to the
    majority of the followers, the leader marks the entry as committed. This
    means the entry is safely stored and can be applied to the state machines
    of all peers. The leader also communicates to followers which entries are
    safe to commit.

  - Client Response: Once an entry is committed, the leader returns the result
    of the command execution to the client.

  - Handling Failures: If a follower fails to replicate a log entry (due to a
    crash or network issue), the leader retries log replication until it
    succeeds, ensuring that the follower eventually stores all committed
    entries.

  - Recovering from Disconnects: If the leader gets disconnected from the
    cluster (due to network issues or crashes), a new leader will be elected.
    Upon rejoining, the old leader will revert to a follower and update its log
    according to the new leader's log.

  - Processing Read Requests: The leader can directly handle read-only client
    requests, but it typically first ensures it is still the leader by
    confirming it can communicate with the majority of the cluster.

  - Term Change: If the leader receives a message from another peer with a
    higher term, it steps down and reverts to a follower, recognizing the
    authority of the higher term.
  """
  @behaviour Bedrock.Raft.Mode

  alias Bedrock.Raft
  alias Bedrock.Raft.Log
  alias Bedrock.Raft.Mode.Leader.FollowerTracking
  alias Bedrock.Raft.TransactionID

  import Bedrock.Raft.Telemetry,
    only: [
      track_consensus_reached: 1,
      track_transaction_added: 2,
      track_append_entries_ack_received: 4,
      track_heartbeat: 1,
      track_append_entries_sent: 5
    ]

  @type t :: %__MODULE__{
          peers: [Raft.peer()],
          quorum: Raft.quorum(),
          term: Raft.election_term(),
          id_sequence: non_neg_integer(),
          follower_tracking: FollowerTracking.t(),
          cancel_timer_fn: function() | nil,
          log: Log.t(),
          interface: module()
        }
  defstruct [
    :peers,
    :quorum,
    :term,
    :id_sequence,
    :follower_tracking,
    :cancel_timer_fn,
    :log,
    :interface
  ]

  @doc """
  Create a new leader. We'll send notices to all the peers, and schedule the
  timer to tick.
  """
  @spec new(
          Raft.election_term(),
          Raft.quorum(),
          [Raft.peer()],
          Log.t(),
          interface :: module()
        ) ::
          t()
  def new(term, quorum, peers, log, interface) do
    # Initialize id_sequence to the index of the newest transaction in the log
    # so we don't generate conflicting transaction IDs
    newest_transaction_id = Log.newest_transaction_id(log)
    initial_id_sequence = TransactionID.index(newest_transaction_id)

    %__MODULE__{
      quorum: quorum,
      peers: peers,
      term: term,
      id_sequence: initial_id_sequence,
      follower_tracking:
        FollowerTracking.new(peers,
          initial_transaction_id: Log.initial_transaction_id(log),
          initial_send_cursor_transaction_id: newest_transaction_id,
          timestamp_fn: &interface.timestamp_in_ms/0
        ),
      log: log,
      interface: interface
    }
    |> set_timer()
  end

  @spec next_id(t()) :: {:ok, t(), Raft.transaction_id()}
  def next_id(t) do
    next_id = t.id_sequence + 1
    id = Log.new_id(t.log, t.term, t.id_sequence + 1)
    {:ok, %{t | id_sequence: next_id}, id}
  end

  @impl true
  @spec vote_requested(
          t(),
          Raft.election_term(),
          candidate :: Raft.peer(),
          candidate_last_transaction_id :: Raft.transaction_id()
        ) :: {:ok, t()} | :become_follower
  def vote_requested(t, term, _, _) when term > t.term, do: :become_follower
  def vote_requested(t, _, _, _), do: {:ok, t}

  @doc """
  """
  @impl true
  @spec vote_received(t(), Raft.election_term(), follower :: Raft.peer()) ::
          :become_follower | {:ok, t()}
  def vote_received(t, term, _) when term > t.term, do: become_follower(t)
  def vote_received(t, _, _), do: {:ok, t}

  @doc """
  Add a transaction to the log. If the transaction is out of order (the
  transaction is not from this term, or is smaller than the newest transaction),
  we'll return an error.
  """
  @impl true
  @spec add_transaction(t(), transaction_payload :: term()) :: {:ok, t(), Raft.transaction_id()}
  def add_transaction(t, transaction_payload) do
    with {:ok, t, new_txn_id} <- next_id(t),
         last_txn_id <- Log.newest_transaction_id(t.log),
         {:ok, log} <-
           Log.append_transactions(t.log, last_txn_id, [
             {new_txn_id, transaction_payload}
           ]) do
      track_transaction_added(t.term, new_txn_id)

      replicate_transaction(%{t | log: log}, new_txn_id)
    end
  end

  # In single-node clusters, the leader itself constitutes the entire cluster
  # so we can immediately commit the transaction and trigger consensus.
  defp replicate_transaction(%{quorum: 0} = t, new_txn_id) do
    case Log.commit_up_to(t.log, new_txn_id) do
      {:ok, committed_log} ->
        track_consensus_reached(new_txn_id)
        :ok = t.interface.consensus_reached(committed_log, new_txn_id, :latest)
        {:ok, %{t | log: committed_log}, new_txn_id}

      :unchanged ->
        {:ok, t, new_txn_id}
    end
  end

  # Multi-node clusters: send append_entries to followers and wait for acks.
  defp replicate_transaction(t, new_txn_id) do
    t = send_append_entries_to_followers(t, t.peers)
    {:ok, t, new_txn_id}
  end

  @doc """
  A follower has responded to an AppendEntries request. Successful responses
  advance matchIndex monotonically. Rejections only backtrack the independent
  send cursor and retry.
  """
  @impl true
  @spec append_entries_ack_received(
          t(),
          Raft.election_term(),
          success :: boolean(),
          request_transaction_id :: Raft.transaction_id(),
          follower :: Raft.peer()
        ) ::
          {:ok, t()}
  def append_entries_ack_received(t, term, success, request_transaction_id, follower)
      when term == t.term do
    if follower in t.peers do
      track_append_entries_ack_received(term, follower, success, request_transaction_id)

      handle_append_entries_response(t, success, request_transaction_id, follower)
      |> then(&{:ok, &1})
    else
      {:ok, t}
    end
  end

  def append_entries_ack_received(t, term, _, _, _) when term > t.term, do: become_follower(t)
  def append_entries_ack_received(t, _, _, _, _), do: {:ok, t}

  defp handle_append_entries_response(t, true, matched_transaction_id, follower) do
    if Log.has_transaction_id?(t.log, matched_transaction_id) do
      FollowerTracking.record_success(t.follower_tracking, follower, matched_transaction_id)

      newest_safe_transaction_id =
        FollowerTracking.newest_safe_transaction_id(t.follower_tracking, t.quorum)

      commit_or_continue_replication(t, follower, newest_safe_transaction_id)
    else
      t
    end
  end

  defp handle_append_entries_response(t, false, rejected_prev_transaction_id, follower) do
    follower_match_transaction_id =
      FollowerTracking.match_transaction_id(t.follower_tracking, follower)

    cond do
      not Log.has_transaction_id?(t.log, rejected_prev_transaction_id) ->
        t

      rejected_prev_transaction_id <= follower_match_transaction_id ->
        t

      true ->
        retry_transaction_id = previous_transaction_id(t.log, rejected_prev_transaction_id)

        FollowerTracking.record_rejection(t.follower_tracking, follower, retry_transaction_id)

        send_append_entries_to_follower(
          t,
          follower,
          FollowerTracking.send_cursor_transaction_id(t.follower_tracking, follower),
          Log.newest_safe_transaction_id(t.log)
        )
    end
  end

  defp commit_or_continue_replication(t, follower, newest_safe_transaction_id) do
    newest_transaction_id = Log.newest_transaction_id(t.log)

    # Raft only commits entries from the leader's current term by counting
    # replicas. Committing one of those entries also commits its preceding
    # entries from older terms indirectly.
    newest_safe_transaction_id =
      if TransactionID.term(newest_safe_transaction_id) == t.term do
        newest_safe_transaction_id
      else
        Log.newest_safe_transaction_id(t.log)
      end

    case Log.commit_up_to(t.log, newest_safe_transaction_id) do
      {:ok, log} ->
        track_consensus_reached(newest_safe_transaction_id)

        consistency =
          if newest_transaction_id == newest_safe_transaction_id, do: :latest, else: :behind

        :ok = t.interface.consensus_reached(log, newest_safe_transaction_id, consistency)

        %{t | log: log} |> send_append_entries_to_followers(t.peers)

      :unchanged ->
        send_append_entries_to_follower_if_needed(t, follower, newest_transaction_id)
    end
  end

  defp previous_transaction_id(log, transaction_id) do
    log
    |> Log.transactions_from(Log.initial_transaction_id(log), transaction_id)
    |> Enum.reverse()
    |> case do
      [{^transaction_id, _}, {previous_transaction_id, _} | _] -> previous_transaction_id
      [{^transaction_id, _}] -> Log.initial_transaction_id(log)
    end
  end

  @doc """
  A ping that is normally directed at a follower has been received. If the term
  is greater than our term, then we will cancel any outstanding timers and
  signal that a new leader has been elected. Otherwise, we'll ignore the ping.
  """
  @impl true
  @spec append_entries_received(
          t(),
          leader_term :: Raft.election_term(),
          prev_transaction_id :: Raft.transaction_id(),
          transactions :: [Raft.transaction()],
          commit_transaction_id :: Raft.transaction_id(),
          from :: Raft.peer()
        ) ::
          {:ok, t()} | :become_follower
  def append_entries_received(t, term, _, _, _, _) when term > t.term, do: t |> become_follower()
  def append_entries_received(t, _, _, _, _, _), do: {:ok, t}

  @doc """
  The timer has ticked. We'll send notices to all the peers, and start the
  timer again.
  """
  @impl true
  @spec timer_ticked(t(), :heartbeat) :: {:ok, t()}
  def timer_ticked(t, :heartbeat) do
    track_heartbeat(t.term)

    active_followers = active_followers(t)

    if active_followers < t.quorum do
      case t.interface.quorum_lost(active_followers, length(t.peers), t.term) do
        :step_down -> become_follower(t)
        :continue -> send_heartbeats_and_continue(t)
      end
    else
      send_heartbeats_and_continue(t)
    end
  end

  def timer_ticked(t, _), do: {:ok, t}

  defp send_heartbeats_and_continue(t) do
    t
    |> send_append_entries_to_followers(
      FollowerTracking.followers_not_seen_in(t.follower_tracking, t.interface.heartbeat_ms())
    )
    |> reset_timer()
    |> then(&{:ok, &1})
  end

  @spec active_followers(t()) :: non_neg_integer()
  defp active_followers(t) do
    not_seen =
      t.follower_tracking
      |> FollowerTracking.followers_not_seen_in(t.interface.heartbeat_ms() * 5)

    length(t.peers) - length(not_seen)
  end

  @spec send_append_entries_to_followers(t(), peers :: [Raft.peer()]) :: t()
  defp send_append_entries_to_followers(t, peers) do
    peers
    |> Enum.reduce(
      t,
      &send_append_entries_to_follower(
        &2,
        &1,
        FollowerTracking.send_cursor_transaction_id(t.follower_tracking, &1),
        Log.newest_safe_transaction_id(t.log)
      )
    )
  end

  defp send_append_entries_to_follower_if_needed(
         t,
         follower,
         newest_transaction_id
       ),
       do: maybe_send_append_entries_to_follower(t, follower, newest_transaction_id)

  defp maybe_send_append_entries_to_follower(t, follower, newest_transaction_id) do
    send_cursor_transaction_id =
      FollowerTracking.send_cursor_transaction_id(t.follower_tracking, follower)

    if send_cursor_transaction_id < newest_transaction_id do
      send_append_entries_to_follower(
        t,
        follower,
        send_cursor_transaction_id,
        Log.newest_safe_transaction_id(t.log)
      )
    else
      t
    end
  end

  defp send_append_entries_to_follower(
         t,
         follower,
         prev_transaction_id,
         newest_safe_transaction_id
       ) do
    transactions =
      Log.transactions_from(t.log, prev_transaction_id, :newest)
      |> Enum.take(10)

    # Pipelining: move the send cursor past what this request carries so the
    # next send continues from here instead of re-sending the same window.
    # This is only an optimistic send position -- matchIndex still advances
    # exclusively on acknowledged success, and a rejection backtracks the
    # cursor again, so a lost request is recovered via heartbeat probe ->
    # rejection -> backtrack.
    if transactions != [] do
      FollowerTracking.advance_send_cursor(
        t.follower_tracking,
        follower,
        transactions |> List.last() |> elem(0)
      )
    end

    track_append_entries_sent(
      t.term,
      follower,
      prev_transaction_id,
      transactions |> Enum.map(&elem(&1, 0)),
      newest_safe_transaction_id
    )

    t.interface.send_event(
      follower,
      {:append_entries, t.term, prev_transaction_id, transactions, newest_safe_transaction_id}
    )

    t
  end

  defp become_follower(t) do
    t |> cancel_timer()
    :become_follower
  end

  @spec reset_timer(t()) :: t()
  defp reset_timer(t), do: t |> cancel_timer() |> set_timer()

  @spec cancel_timer(t()) :: t()
  defp cancel_timer(t) when is_nil(t.cancel_timer_fn), do: t

  defp cancel_timer(t) do
    t.cancel_timer_fn.()
    %{t | cancel_timer_fn: nil}
  end

  @spec set_timer(t()) :: t()
  defp set_timer(t), do: %{t | cancel_timer_fn: t.interface.timer(:heartbeat)}
end
