defmodule Bedrock.Raft.Mode.Leader.FollowerTracking do
  @moduledoc """
  The FollowerTracking module keeps the replication cursor and acknowledged
  match position for each follower separate. The cursor may move backwards
  after a rejection; the match position only moves forwards after a successful
  response.
  """
  alias Bedrock.Raft

  @type timestamp_fn() :: (-> integer())
  @type t :: %__MODULE__{
          table: :ets.table(),
          timestamp_fn: timestamp_fn()
        }

  defstruct table: nil,
            timestamp_fn: nil

  defp default_timestamp_impl, do: :os.system_time(:millisecond)

  @spec new(
          followers :: [Raft.peer()],
          opts :: [
            initial_transaction_id: Raft.transaction_id(),
            initial_send_cursor_transaction_id: Raft.transaction_id(),
            timestamp_fn: timestamp_fn()
          ]
        ) :: t()
  def new(followers, opts) do
    t = %__MODULE__{
      table: :ets.new(:follower_tracking, [:ordered_set]),
      timestamp_fn: opts[:timestamp_fn] || (&default_timestamp_impl/0)
    }

    initial_transaction_id = opts[:initial_transaction_id] || :unknown

    initial_send_cursor_transaction_id =
      opts[:initial_send_cursor_transaction_id] || initial_transaction_id

    now = timestamp(t)

    :ets.insert(
      t.table,
      followers
      |> Enum.map(&{&1, initial_send_cursor_transaction_id, initial_transaction_id, now})
    )

    t
  end

  @spec timestamp(t()) :: integer()
  def timestamp(%{timestamp_fn: timestamp_fn}), do: timestamp_fn.()

  @spec send_cursor_transaction_id(t(), Raft.peer()) :: Raft.transaction_id()
  def send_cursor_transaction_id(t, follower) do
    t.table
    |> :ets.lookup(follower)
    |> case do
      [{^follower, send_cursor_transaction_id, _, _}] -> send_cursor_transaction_id
      [] -> raise "follower not found: #{inspect(follower)}"
    end
  end

  @spec match_transaction_id(t(), Raft.peer()) :: Raft.transaction_id()
  def match_transaction_id(t, follower) do
    t.table
    |> :ets.lookup(follower)
    |> case do
      [{^follower, _, match_transaction_id, _}] -> match_transaction_id
      [] -> raise "follower not found: #{inspect(follower)}"
    end
  end

  def followers_not_seen_in(t, n_milliseconds) do
    since = timestamp(t) - n_milliseconds

    t.table
    |> :ets.select([{{:"$1", :_, :_, :"$4"}, [{:>, since, :"$4"}], [:"$1"]}])
  end

  @doc """
  Find the highest commit that a majority of followers have acknowledged. We
  can do this by sorting the list of last_transaction_id_acked and taking the
  quorum-th-from-last element -- every follower above this index has already
  acknowledged *at-least* up to this transaction.
  """
  @spec newest_safe_transaction_id(t(), quorum :: non_neg_integer()) ::
          Raft.transaction_id()
  def newest_safe_transaction_id(t, quorum) do
    transaction_ids =
      t.table
      |> :ets.select([{{:_, :_, :"$3", :_}, [], [:"$3"]}])
      |> Enum.sort()

    cond do
      Enum.empty?(transaction_ids) -> nil
      quorum == 0 -> List.first(transaction_ids)
      quorum > length(transaction_ids) -> List.first(transaction_ids)
      true -> Enum.at(transaction_ids, -quorum)
    end
  end

  @doc """
  Record successful replication through `match_transaction_id`.

  Both the match position and cursor are monotonic on success, so a delayed
  response for an older request cannot regress either value.
  """
  @spec record_success(t(), Raft.peer(), Raft.transaction_id()) :: t()
  def record_success(t, follower, match_transaction_id) do
    now = timestamp(t)

    [{^follower, send_cursor_transaction_id, old_match_transaction_id, _}] =
      :ets.lookup(t.table, follower)

    :ets.update_element(t.table, follower, [
      {2, max(send_cursor_transaction_id, match_transaction_id)},
      {3, max(old_match_transaction_id, match_transaction_id)},
      {4, now}
    ])

    t
  end

  @doc """
  Move the replication cursor backwards after a rejection without changing the
  acknowledged match position. A delayed rejection cannot move a cursor that
  has already backtracked even farther forwards again.
  """
  @spec record_rejection(t(), Raft.peer(), Raft.transaction_id()) :: t()
  def record_rejection(t, follower, retry_transaction_id) do
    now = timestamp(t)
    [{^follower, send_cursor_transaction_id, _, _}] = :ets.lookup(t.table, follower)

    :ets.update_element(t.table, follower, [
      {2, min(send_cursor_transaction_id, retry_transaction_id)},
      {4, now}
    ])

    t
  end
end
