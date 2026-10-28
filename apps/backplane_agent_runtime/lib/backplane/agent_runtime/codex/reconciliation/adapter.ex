defmodule Backplane.AgentRuntime.Codex.Reconciliation.Adapter do
  @moduledoc """
  Trusted host storage for immutable recovery evidence and separate closure receipts.

  Evidence reads must not perform cleanup. The host holds exclusive recovery and
  Store writer authority from the authoritative reads through receipt CAS. Receipt
  revision zero means absent; the first successful CAS writes revision one.
  A durable adapter documents its atomicity, isolation and persistence boundary.
  No runtime capability, callback or Store context belongs in serialized evidence.
  """

  alias Backplane.AgentRuntime.Error

  @callback mode() :: :ephemeral | :durable
  @callback load_evidence(term(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @callback runtime_store(term(), String.t()) :: {:ok, {module(), term()}} | {:error, Error.t()}
  @callback load_receipt(term(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @doc """
  Optional staged-export journal read under the same exclusive writer authority.

  Returns bounded portable entries from admission (revision 1) through the exact
  authoritative Store revision. Each entry has string keys `revision`,
  `prior_revision`, `prior_incarnation`, `incarnation`, `kind`, and canonical command
  `input`. Normal commands retain incarnation; `fence` advances it, has an empty
  input, and explicitly binds the preceding revision/incarnation. Reads never
  execute effects. This capability does not change the Store write contract.
  """
  @callback load_recovery_journal(term(), map()) :: {:ok, [map()]} | {:error, Error.t()}
  @optional_callbacks load_recovery_journal: 2

  @callback compare_and_swap_receipt(term(), String.t(), non_neg_integer(), map()) ::
              {:ok, map()} | {:error, Error.t()}
end
