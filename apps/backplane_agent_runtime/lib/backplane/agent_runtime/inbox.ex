defmodule Backplane.AgentRuntime.Inbox do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Bounded receiver inbox with payload-digest deduplication.

  A duplicate correlation ID with the same digest returns the existing receipt.
  The same key with changed payload conflicts. Overflow is explicit.
  """

  @type t :: map()

  @spec new(non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def new(limit) when is_integer(limit) and limit >= 0 do
    {:ok, %{limit: limit, accepted: %{}, order: []}}
  end

  @spec deliver(t(), map()) ::
          {:ok, t(), %{status: :accepted | :duplicate}} | {:error, Error.t()}
  def deliver(inbox, message) when is_map(inbox) and is_map(message) do
    with {:ok, message} <- validate_message(message),
         {:ok, digest} <- payload_digest(message) do
      case Map.get(inbox.accepted, message.correlation_id) do
        %{digest: ^digest} ->
          {:ok, inbox,
           %{status: :accepted, correlation_id: message.correlation_id, digest: digest}}

        %{digest: existing_digest} ->
          {:error,
           Error.new(:resource_conflict, "payload digest conflict",
             details: %{existing: existing_digest, received: digest}
           )}

        nil ->
          admit(inbox, message, digest)
      end
    end
  end

  defp admit(inbox, message, digest) do
    cond do
      map_size(inbox.accepted) >= inbox.limit ->
        {:error, Error.new(:overloaded, "inbox is full")}

      true ->
        accepted =
          Map.put(inbox.accepted, message.correlation_id, %{
            digest: digest,
            expires_at: message.expires_at
          })

        {:ok, %{inbox | accepted: accepted, order: inbox.order ++ [message.correlation_id]},
         %{status: :accepted, correlation_id: message.correlation_id, digest: digest}}
    end
  end

  defp validate_message(%{
         kind: kind,
         sender: sender,
         recipient: recipient,
         correlation_id: correlation_id,
         payload: payload,
         expires_at: expires_at
       })
       when is_atom(kind) and is_binary(sender) and is_binary(recipient) and
              is_binary(correlation_id) and is_map(payload) and is_integer(expires_at) do
    {:ok,
     %{
       kind: kind,
       sender: sender,
       recipient: recipient,
       correlation_id: correlation_id,
       payload: payload,
       expires_at: expires_at
     }}
  end

  defp validate_message(_), do: {:error, Error.new(:validation, "invalid message")}

  defp payload_digest(message) do
    {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(message.payload)) |> Base.encode16()}
  end
end
