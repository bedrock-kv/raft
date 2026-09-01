defmodule Bedrock.Raft.Log.TupleInMemoryLog do
  @moduledoc """
  This module implements a tuple in-memory log for use with the Raft consensus
  algorithm. It assumes the use of tuple transactions ids in the form
  {term, sequence}. The log is implemented using an ETS table with the
  :ordered_set option, which maintains transactions in the order they were
  inserted.
  """
  alias Bedrock.Raft
  alias Bedrock.Raft.TransactionID

  @type t :: %__MODULE__{
          transactions: :ets.table(),
          last_commit: Raft.tuple_transaction_id() | nil,
          current_term: Raft.election_term(),
          voted_for: Raft.peer() | nil
        }
  defstruct ~w[
    transactions
    last_commit
    current_term
    voted_for
  ]a

  @spec new() :: t()
  def new,
    do: %__MODULE__{
      transactions: :ets.new(:tuple_in_memory_log, [:ordered_set]),
      current_term: 0
    }

  defimpl Bedrock.Raft.Log do
    @type t :: Bedrock.Raft.Log.TupleInMemoryLog.t()

    @initial_transaction_id TransactionID.new(0, 0)

    @impl true
    def new_id(_t, term, sequence), do: TransactionID.new(term, sequence)

    @impl true
    def append_transactions(t, @initial_transaction_id, transactions) do
      true =
        :ets.insert(
          t.transactions,
          transactions |> Enum.map(&normalize_transaction(t, &1))
        )

      {:ok, t}
    end

    def append_transactions(t, prev_transaction_id, transactions)
        when is_tuple(prev_transaction_id) do
      :ets.lookup(t.transactions, prev_transaction_id)
      |> case do
        [{^prev_transaction_id, _}] ->
          true =
            :ets.insert_new(
              t.transactions,
              transactions |> Enum.map(&normalize_transaction(t, &1))
            )

          {:ok, t}

        [] ->
          {:error, :prev_transaction_not_found}
      end
    end

    @impl true
    def purge_transactions_after(t, newest_txn_id) do
      cond do
        newest_txn_id < newest_safe_transaction_id(t) ->
          {:error, :would_delete_committed_transactions}

        # Nothing sorts after newest_txn_id, so there is nothing to delete.
        # The select_delete below walks the entire table, and the follower
        # purges before every append, so this no-op guard keeps the in-order
        # append hot path free of full-table scans.
        newest_txn_id >= newest_transaction_id(t) ->
          {:ok, t}

        true ->
          :ets.select_delete(t.transactions, match_gt_for_delete(newest_txn_id))
          {:ok, t}
      end
    end

    @impl true
    def initial_transaction_id(_t), do: @initial_transaction_id

    @impl true
    def commit_up_to(_t, @initial_transaction_id), do: :unchanged

    def commit_up_to(t, transaction_id)
        when is_tuple(transaction_id) and transaction_id > t.last_commit,
        do: {:ok, %{t | last_commit: transaction_id}}

    def commit_up_to(_t, _transaction_id), do: :unchanged

    @impl true
    def newest_transaction_id(t) do
      :ets.last(t.transactions)
      |> case do
        :"$end_of_table" -> @initial_transaction_id
        transaction_id -> transaction_id
      end
    end

    @impl true
    def newest_safe_transaction_id(t), do: t.last_commit || initial_transaction_id(t)

    @impl true
    def has_transaction_id?(_t, @initial_transaction_id), do: true
    def has_transaction_id?(t, transaction_id), do: :ets.member(t.transactions, transaction_id)

    @impl true
    def previous_transaction_id(t, transaction_id) do
      case :ets.prev(t.transactions, transaction_id) do
        :"$end_of_table" -> initial_transaction_id(t)
        previous_transaction_id -> previous_transaction_id
      end
    end

    @impl true
    def transactions_to(t, :newest),
      do: transactions_from(t, initial_transaction_id(t), newest_transaction_id(t))

    def transactions_to(t, :newest_safe),
      do: transactions_from(t, initial_transaction_id(t), newest_safe_transaction_id(t))

    @impl true
    def transactions_from(t, from, to), do: transactions_from(t, from, to, :infinity)

    @impl true
    def transactions_from(t, from, :newest, limit),
      do: transactions_from(t, from, newest_transaction_id(t), limit)

    def transactions_from(t, from, :newest_safe, limit),
      do: transactions_from(t, from, newest_safe_transaction_id(t), limit)

    # A bounded key walk over the ordered_set: O(result + log n), where the
    # previous match-spec select traversed the entire table regardless of the
    # requested range. `from` is exclusive. When `from` is not present in the
    # log the walk returns the transactions that sort after it; the old
    # select-based implementation raised a CaseClauseError in that situation.
    def transactions_from(t, from, to, limit),
      do: walk_forward(t.transactions, from, to, limit, [])

    defp walk_forward(_table, _key, _to, 0, acc), do: Enum.reverse(acc)

    defp walk_forward(table, key, to, limit, acc) do
      case :ets.next(table, key) do
        :"$end_of_table" ->
          Enum.reverse(acc)

        next_key when next_key > to ->
          Enum.reverse(acc)

        next_key ->
          case :ets.lookup(table, next_key) do
            [transaction] ->
              walk_forward(table, next_key, to, decrement_limit(limit), [transaction | acc])

            [] ->
              # The key vanished between :ets.next and the lookup: the table
              # owner truncated the log concurrently. Halt the walk. The old
              # single-select read was one atomic, isolated BIF -- a
              # point-in-time snapshot that could not be interrupted. The
              # bounded walk traded that snapshot for O(result + log n)
              # reads; this branch makes the resulting weak consistency
              # non-crashing (see the consistency note on the Log protocol).
              Enum.reverse(acc)
          end
      end
    end

    defp decrement_limit(:infinity), do: :infinity
    defp decrement_limit(limit), do: limit - 1

    def match_gt_for_delete(gt),
      do: [{{:"$1", :"$2"}, [{:>, :"$1", {:const, gt}}], [true]}]

    @doc """
    Ensure that the given transaction is in the correct format for the log,
    converting it only if necessary.
    """
    @spec normalize_transaction(t(), Raft.transaction()) :: Raft.transaction()
    def normalize_transaction(_t, {transaction_id, _data} = transaction)
        when is_tuple(transaction_id),
        do: transaction

    def normalize_transaction(_t, {transaction_id, data}) when is_binary(transaction_id),
      do: {transaction_id |> TransactionID.decode(), data}

    @impl true
    def current_term(t), do: t.current_term

    @impl true
    def save_current_term(t, term) when term > t.current_term,
      do: save_election_state(t, term, nil)

    def save_current_term(t, _term), do: {:ok, t}

    @impl true
    def voted_for(t), do: t.voted_for

    @impl true
    def save_election_state(t, term, voted_for) when term > t.current_term,
      do: {:ok, %{t | current_term: term, voted_for: voted_for}}

    def save_election_state(%{voted_for: nil} = t, term, voted_for) when term == t.current_term,
      do: {:ok, %{t | voted_for: voted_for}}

    def save_election_state(%{voted_for: voted_for} = t, term, voted_for)
        when term == t.current_term,
        do: {:ok, t}

    def save_election_state(t, term, _voted_for) when term == t.current_term,
      do: {:error, :already_voted}

    def save_election_state(_t, _term, _voted_for), do: {:error, :stale_term}
  end
end
