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
          current_term: Raft.election_term()
        }
  defstruct ~w[
    transactions
    last_commit
    current_term
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
      if newest_txn_id < newest_safe_transaction_id(t) do
        {:error, :would_delete_committed_transactions}
      else
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
    def transactions_to(t, :newest),
      do: transactions_from(t, initial_transaction_id(t), newest_transaction_id(t))

    def transactions_to(t, :newest_safe),
      do: transactions_from(t, initial_transaction_id(t), newest_safe_transaction_id(t))

    @impl true
    def transactions_from(t, from, :newest),
      do: transactions_from(t, from, newest_transaction_id(t))

    def transactions_from(t, from, :newest_safe),
      do: transactions_from(t, from, newest_safe_transaction_id(t))

    def transactions_from(t, @initial_transaction_id, to),
      do: :ets.select(t.transactions, match_lte(to))

    def transactions_from(t, from, to) do
      :ets.select(t.transactions, match_gte_lte(from, to))
      |> case do
        [{^from, _data} | transactions] -> transactions
        [] -> []
      end
    end

    def match_gt_for_delete(gt),
      do: [{{:"$1", :"$2"}, [{:>, :"$1", {:const, gt}}], [true]}]

    def match_lte(lte),
      do: [{{:"$1", :"$2"}, [{:"=<", :"$1", {:const, lte}}], [{{:"$1", :"$2"}}]}]

    def match_gte_lte(gte, lte),
      do: [
        {{:"$1", :"$2"}, [{:>=, :"$1", {:const, gte}}, {:"=<", :"$1", {:const, lte}}],
         [{{:"$1", :"$2"}}]}
      ]

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
    def save_current_term(t, term), do: {:ok, %{t | current_term: term}}
  end
end
