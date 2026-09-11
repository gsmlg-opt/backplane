defmodule Backplane.AgentRuntime.Message do
  @moduledoc """
  Typed runtime messages with trusted provenance and bounded payload/TTL.

  Payload and status messages never start a model run. Only task requests can
  trigger admission, and that decision remains with the receiving policy.
  """

  @type t :: map()

  @default_payload_limit 65_536

  @valid_kinds [:notification, :progress, :acknowledgement, :result, :task_request]

  @spec build(map(), keyword()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def build(input, opts \\ [])

  def build(input, opts) when is_map(input) and is_list(opts) do
    payload_limit = Keyword.get(opts, :payload_limit, @default_payload_limit)

    with {:ok, sender} <- require_binary(input, :sender, "sender"),
         {:ok, recipient} <- require_binary(input, :recipient, "recipient"),
         {:ok, kind} <- require_kind(input),
         {:ok, correlation_id} <- require_binary(input, :correlation_id, "correlation_id"),
         {:ok, payload} <- require_payload(input, payload_limit),
         {:ok, expires_at} <- require_ttl(input) do
      {:ok,
       %{
         sender: sender,
         recipient: recipient,
         kind: kind,
         correlation_id: correlation_id,
         payload: payload,
         expires_at: expires_at,
         provenance: Map.get(input, :provenance, %{})
       }}
    end
  end

  def build(_input, _opts),
    do: {:error, Backplane.AgentRuntime.Error.new(:validation, "message input must be a map")}

  @spec task_request?(t()) :: boolean()
  def task_request?(%{kind: :task_request}), do: true
  def task_request?(_), do: false

  defp require_binary(input, key, label) do
    value = Map.get(input, key)

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, Backplane.AgentRuntime.Error.new(:validation, "#{label} is required")}
    end
  end

  defp require_kind(input) do
    value = Map.get(input, :kind)

    if value in @valid_kinds do
      {:ok, value}
    else
      {:error, Backplane.AgentRuntime.Error.new(:validation, "invalid message kind")}
    end
  end

  defp require_payload(input, payload_limit) do
    payload = Map.get(input, :payload, %{})
    size = :erlang.external_size(payload)

    cond do
      not is_map(payload) ->
        {:error, Backplane.AgentRuntime.Error.new(:validation, "payload must be a map")}

      size > payload_limit ->
        {:error,
         Backplane.AgentRuntime.Error.new(:resource_conflict, "message payload exceeds bound",
           details: %{limit: payload_limit, size: size}
         )}

      true ->
        {:ok, payload}
    end
  end

  defp require_ttl(input) do
    value = Map.get(input, :expires_at)

    if is_integer(value) and value >= 0 do
      {:ok, value}
    else
      {:error, Backplane.AgentRuntime.Error.new(:validation, "message TTL is required")}
    end
  end
end
