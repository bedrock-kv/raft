defprotocol Bedrock.Raft.Log do
  @moduledoc """
  The interface for the Raft transaction log.
  """

  @type t :: any()

  alias Bedrock.Raft

  @doc """
  Create a new log with the given term and sequence number in the format
  expected by the log implementation.
  """
  def new_id(t, term, sequence)

  @doc """
  Purge the log of all transactions after the given id.

  A purge that would remove committed transactions is rejected because Raft's
  commit index must never decrease.
  """
  @spec purge_transactions_after(t(), Raft.transaction_id()) ::
          {:ok, t()} | {:error, :would_delete_committed_transactions}
  def purge_transactions_after(t, transaction_id)

  @doc """
  Append the given block of transactions to the log, starting at the given
  previous transaction's id. If we can't find the previous transaction, we
  return an error.
  """
  @spec append_transactions(
          t(),
          prev_transaction_id :: Raft.transaction_id(),
          transactions :: [Raft.transaction()]
        ) ::
          {:ok, t()} | {:error, :prev_transaction_not_found}
  def append_transactions(t, prev_transaction_id, transactions)

  @doc """
  Get the initial transaction for the log.
  """
  @spec initial_transaction_id(t()) :: Raft.transaction_id()
  def initial_transaction_id(t)

  @doc """
  Mark all transactions up to and including the given transaction as committed.
  """
  @spec commit_up_to(t(), Raft.transaction_id()) :: {:ok, t()} | :unchanged
  def commit_up_to(t, transaction)

  @doc """
  Get the newest transaction in the log.
  """
  @spec newest_transaction_id(t()) :: Raft.transaction_id()
  def newest_transaction_id(t)

  @doc """
  Get the newest transaction in the log that has been safely appended to the
  logs of a quorum of peers in the cluster.
  """
  @spec newest_safe_transaction_id(t()) :: Raft.transaction_id()
  def newest_safe_transaction_id(t)

  @doc """
  Does the log contain the given transaction?
  """
  @spec has_transaction_id?(t(), Raft.transaction_id()) :: boolean()
  def has_transaction_id?(t, transaction_id)

  @doc """
  Get a list of transactions that have occurred up to the the given transaction.
  """
  @spec transactions_to(t(), to :: Raft.transaction_id() | :newest | :newest_safe) ::
          [Raft.transaction()]
  def transactions_to(t, to)

  @doc """
  Get a list of transactions that have occurred using the given transaction
  as a starting point -- not inclusive of the starting point.
  """
  @spec transactions_from(
          t(),
          from :: Raft.transaction_id(),
          to :: Raft.transaction_id() | :newest | :newest_safe
        ) :: [Raft.transaction()]
  def transactions_from(t, from, to)

  @doc """
  Get the current term for the log. This is the latest election term the
  server has seen and must be persisted across restarts according to the
  Raft specification.
  """
  @spec current_term(t()) :: Raft.election_term()
  def current_term(t)

  @doc """
  Save the current term to persistent storage. This must be called before
  responding to RPCs to ensure Raft safety guarantees are maintained.
  """
  @spec save_current_term(t(), Raft.election_term()) :: {:ok, t()}
  def save_current_term(t, term)
end
