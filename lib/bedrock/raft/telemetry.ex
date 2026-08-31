defmodule Bedrock.Raft.Telemetry do
  alias Bedrock.Raft

  @spec track_ignored_event(event :: term(), from :: Raft.peer()) :: :ok
  def track_ignored_event(event, from) do
    :telemetry.execute([:bedrock, :raft, :ignored_event], %{at: now()}, %{
      event: event,
      from: from
    })
  end

  @spec track_became_follower(Raft.election_term(), Raft.peer()) :: :ok
  def track_became_follower(term, leader) do
    :telemetry.execute([:bedrock, :raft, :mode_change], %{at: now()}, %{
      mode: :follower,
      term: term,
      leader: leader
    })
  end

  @spec track_became_candidate(Raft.election_term(), Raft.quorum(), [Raft.peer()]) :: :ok
  def track_became_candidate(term, quorum, peers) do
    :telemetry.execute([:bedrock, :raft, :mode_change], %{at: now()}, %{
      mode: :candidate,
      term: term,
      quorum: quorum,
      peers: peers
    })
  end

  @spec track_became_leader(Raft.election_term(), Raft.quorum(), [Raft.peer()]) :: :ok
  def track_became_leader(term, quorum, peers) do
    :telemetry.execute([:bedrock, :raft, :mode_change], %{at: now()}, %{
      mode: :leader,
      term: term,
      quorum: quorum,
      peers: peers
    })
  end

  @spec track_consensus_reached(Raft.transaction_id()) :: :ok
  def track_consensus_reached(transaction_id) do
    :telemetry.execute([:bedrock, :raft, :consensus_reached], %{at: now()}, %{
      transaction_id: transaction_id
    })
  end

  @spec track_leadership_change(Raft.peer(), Raft.election_term()) :: :ok
  def track_leadership_change(leader, term) do
    :telemetry.execute([:bedrock, :raft, :leadership_change], %{at: now()}, %{
      leader: leader,
      term: term
    })
  end

  @spec track_request_votes(Raft.election_term(), [Raft.peer()], Raft.transaction_id()) :: :ok
  def track_request_votes(term, peers, newest_transaction_id) do
    :telemetry.execute([:bedrock, :raft, :request_votes], %{at: now()}, %{
      term: term,
      peers: peers,
      newest_transaction_id: newest_transaction_id
    })
  end

  @spec track_vote_received(Raft.election_term(), follower :: Raft.peer()) :: :ok
  def track_vote_received(term, follower) do
    :telemetry.execute([:bedrock, :raft, :vote_received], %{at: now()}, %{
      term: term,
      follower: follower
    })
  end

  @spec track_vote_sent(Raft.election_term(), candidate :: Raft.peer()) :: :ok
  def track_vote_sent(term, candidate) do
    :telemetry.execute([:bedrock, :raft, :vote_sent], %{at: now()}, %{
      term: term,
      candidate: candidate
    })
  end

  @spec track_election_ended(Raft.election_term(), [Raft.peer()], non_neg_integer()) :: :ok
  def track_election_ended(term, votes, quorum) do
    :telemetry.execute([:bedrock, :raft, :election_ended], %{at: now()}, %{
      term: term,
      votes: votes,
      quorum: quorum
    })
  end

  @spec track_transaction_added(Raft.election_term(), Raft.transaction_id()) :: :ok
  def track_transaction_added(term, transaction_id) do
    :telemetry.execute([:bedrock, :raft, :transaction_added], %{at: now()}, %{
      term: term,
      transaction_id: transaction_id
    })
  end

  @spec track_append_entries_ack_sent(
          Raft.election_term(),
          Raft.peer(),
          boolean(),
          Raft.transaction_id()
        ) :: :ok
  def track_append_entries_ack_sent(term, leader, success, request_transaction_id) do
    :telemetry.execute([:bedrock, :raft, :append_entries_ack_sent], %{at: now()}, %{
      term: term,
      leader: leader,
      success: success,
      request_transaction_id: request_transaction_id
    })
  end

  @spec track_append_entries_ack_received(
          Raft.election_term(),
          Raft.peer(),
          boolean(),
          Raft.transaction_id()
        ) :: :ok
  def track_append_entries_ack_received(term, follower, success, request_transaction_id) do
    :telemetry.execute([:bedrock, :raft, :append_entries_ack_received], %{at: now()}, %{
      term: term,
      follower: follower,
      success: success,
      request_transaction_id: request_transaction_id
    })
  end

  @spec track_heartbeat(Raft.election_term()) :: :ok
  def track_heartbeat(term) do
    :telemetry.execute([:bedrock, :raft, :heartbeat], %{at: now()}, %{
      term: term
    })
  end

  @spec track_append_entries_sent(
          Raft.election_term(),
          leader :: Raft.peer(),
          prev_transaction_id :: Raft.transaction_id(),
          [Raft.transaction()],
          commit_transaction_id :: Raft.transaction_id()
        ) :: :ok
  def track_append_entries_sent(
        term,
        follower,
        prev_transaction_id,
        transaction_ids,
        newest_safe_transaction_id
      ) do
    :telemetry.execute([:bedrock, :raft, :append_entries_sent], %{at: now()}, %{
      follower: follower,
      term: term,
      prev_transaction_id: prev_transaction_id,
      transaction_ids: transaction_ids,
      newest_safe_transaction_id: newest_safe_transaction_id
    })
  end

  @spec track_append_entries_received(
          Raft.election_term(),
          leader :: Raft.peer(),
          prev_transaction_id :: Raft.transaction_id(),
          [Raft.transaction()],
          commit_transaction_id :: Raft.transaction_id()
        ) :: :ok
  def track_append_entries_received(
        term,
        leader,
        prev_transaction_id,
        transaction_ids,
        commit_transaction_id
      ) do
    :telemetry.execute([:bedrock, :raft, :append_entries_received], %{at: now()}, %{
      term: term,
      leader: leader,
      prev_transaction_id: prev_transaction_id,
      transaction_ids: transaction_ids,
      commit_transaction_id: commit_transaction_id
    })
  end

  defp now, do: :os.system_time(:millisecond)
end
