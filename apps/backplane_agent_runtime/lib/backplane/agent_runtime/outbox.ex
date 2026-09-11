defmodule Backplane.AgentRuntime.Outbox do
  @moduledoc """
  Sender-intent outbox with idempotency and bounded replay.

  The same submission ID with the same payload returns the existing receipt.
  A changed payload conflicts. Replay never evicts live idempotency state.
  """

  @type t :: map()

  @spec new(non_neg_integer()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def new(limit) when is_integer(limit) and limit >= 0 do
    {:ok, %{limit: limit, submissions: %{}, order: []}}
  end

  @spec submit(t(), String.t(), map()) ::
          {:ok, t(), %{status: :submitted | :duplicate}}
          | {:error, Backplane.AgentRuntime.Error.t()}
  def submit(outbox, submission_id, payload)
      when is_binary(submission_id) and is_map(payload) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(payload)) |> Base.encode16()

    case Map.get(outbox.submissions, submission_id) do
      %{digest: ^digest} ->
        {:ok, outbox, %{status: :submitted, submission_id: submission_id, digest: digest}}

      %{digest: existing_digest} ->
        {:error,
         Backplane.AgentRuntime.Error.new(:resource_conflict, "submission payload conflict",
           details: %{existing: existing_digest, received: digest}
         )}

      nil ->
        admit(outbox, submission_id, digest)
    end
  end

  @spec replay(t(), non_neg_integer()) ::
          {:ok, list()} | {:error, Backplane.AgentRuntime.Error.t()}
  def replay(outbox, cursor) when is_integer(cursor) and cursor >= 0 do
    if cursor < max(0, length(outbox.order) - outbox.limit) do
      {:error, Backplane.AgentRuntime.Error.new(:not_found, "cursor expired")}
    else
      {:ok, Enum.reject(outbox.order, &(&1 < cursor))}
    end
  end

  defp admit(outbox, submission_id, digest) do
    cond do
      map_size(outbox.submissions) >= outbox.limit ->
        {:error, Backplane.AgentRuntime.Error.new(:overloaded, "outbox is full")}

      true ->
        submissions =
          Map.put(outbox.submissions, submission_id, %{digest: digest, state: :submitted})

        {:ok, %{outbox | submissions: submissions, order: outbox.order ++ [submission_id]},
         %{status: :submitted, submission_id: submission_id, digest: digest}}
    end
  end
end
