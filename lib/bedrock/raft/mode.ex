defmodule Bedrock.Raft.Mode do
  @moduledoc false
  alias Bedrock.Raft

  @callback timer_ticked(any(), :heartbeat | :election) :: {:ok, any()} | :become_candidate

  @callback add_transaction(any(), transaction_payload :: term()) ::
              {:ok, any(), Raft.transaction_id()} | {:error, :not_leader}

  @callback vote_requested(
              any(),
              Raft.election_term(),
              candidate :: Raft.peer(),
              candidate_last_transaction_id :: Raft.transaction_id()
            ) :: {:ok, any()} | :become_follower

  @callback vote_received(any(), Raft.election_term(), follower :: Raft.peer()) ::
              :become_leader | :become_follower | {:ok, any()}

  @callback append_entries_ack_received(
              any(),
              Raft.election_term(),
              success :: boolean(),
              request_transaction_id :: Raft.transaction_id(),
              follower :: Raft.peer()
            ) :: {:ok, any()} | :become_follower

  @callback append_entries_received(
              any(),
              leader_term :: Raft.election_term(),
              prev_transaction_id :: Raft.transaction_id(),
              transactions :: [Raft.transaction()],
              commit_transaction_id :: Raft.transaction_id(),
              from :: Raft.peer()
            ) ::
              {:ok, any()} | :become_follower
end
