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

  Reads are safe from processes other than the log owner: when the owner
  truncates the log concurrently (`purge_transactions_after/2`), a read must
  never crash, but may observe a result that is shortened or mixed across the
  truncation -- pre-truncation entries followed by re-appended ones, matching
  no single log state. Because `purge_transactions_after/2` refuses to delete
  committed entries, reads bounded by `:newest_safe` are stable; only reads
  covering the uncommitted suffix (`:newest`) can observe this churn. The
  same consistency applies to `transactions_from/4` and `transactions_to/2`.
  """
  @spec transactions_from(
          t(),
          from :: Raft.transaction_id(),
          to :: Raft.transaction_id() | :newest | :newest_safe
        ) :: [Raft.transaction()]
  def transactions_from(t, from, to)

  @doc """
  Same as `transactions_from/3`, but returns at most `limit` transactions.

  A `limit` of `:infinity` behaves exactly like `transactions_from/3`, and a
  limit of `0` returns an empty list. Implementations should answer in
  O(limit + log n) time -- the replication hot path fetches one bounded batch
  per AppendEntries request through this function.
  """
  @spec transactions_from(
          t(),
          from :: Raft.transaction_id(),
          to :: Raft.transaction_id() | :newest | :newest_safe,
          limit :: non_neg_integer() | :infinity
        ) :: [Raft.transaction()]
  def transactions_from(t, from, to, limit)

  @doc """
  Get the current term for the log. This is the latest election term the
  server has seen and must be persisted across restarts according to the
  Raft specification.
  """
  @spec current_term(t()) :: Raft.election_term()
  def current_term(t)

  @doc """
  Save the current term to persistent storage. Advancing the term also clears
  any vote from an earlier term. This must be called before responding to RPCs
  to ensure Raft safety guarantees are maintained.
  """
  @spec save_current_term(t(), Raft.election_term()) :: {:ok, t()}
  def save_current_term(t, term)

  @doc """
  Get the candidate that received this server's vote in the current term, or
  `nil` if the server has not voted.

  Like `current_term/1`, this value is persistent Raft election state and must
  survive reconstruction of the protocol state machine.
  """
  @spec voted_for(t()) :: Raft.peer() | nil
  def voted_for(t)

  @doc """
  Atomically save the current term and the candidate voted for in that term.

  Implementations must make both values durable before returning. Advancing to
  a new term uses `nil` for `voted_for`; granting a vote stores the candidate.
  Once a candidate is stored, an equal-term write must not change or clear it
  and returns `{:error, :already_voted}` instead. Writes below the durable term
  return `{:error, :stale_term}`.
  """
  @spec save_election_state(t(), Raft.election_term(), Raft.peer() | nil) ::
          {:ok, t()} | {:error, :already_voted | :stale_term}
  def save_election_state(t, term, voted_for)

  @doc """
  Get the id of the newest transaction in the log that is older than the
  given transaction id, or the initial transaction id when no such
  transaction exists (including when the given id is the initial id itself).

  Implementations should answer in at most O(log n) time; the leader consults
  this on every rejected AppendEntries response to backtrack its send cursor.
  """
  @spec previous_transaction_id(t(), Raft.transaction_id()) :: Raft.transaction_id()
  def previous_transaction_id(t, transaction_id)
end
