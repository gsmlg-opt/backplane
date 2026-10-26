defmodule Backplane.HostAgent.Memory.Hooks.OpenClaw do
  @moduledoc "Normalizes explicit OpenClaw occurrences into the existing durable capture path."
  alias Backplane.HostAgent.Memory.EventEnvelope
  alias Backplane.OpenClawCaptureContract, as: Contract

  def supported_hooks, do: Contract.hooks()

  def normalize(hook, source, %{host_id: host_id}) when is_binary(host_id) and host_id != "" do
    with {:ok, event_type} <- Contract.validate(hook, source) do
      payload = %{
        "hook" => hook,
        "source" => source,
        "repository_sources" => Map.get(source, "repository_sources", [])
      }

      {:ok,
       %{
         schema_version: 1,
         event_id: source["event_id"],
         host_id: host_id,
         agent_id: source["agent_id"],
         client_id: "openclaw",
         integration: "openclaw",
         session_id: source["session_id"],
         parent_session_id: source["parent_session_id"],
         project: source["cwd"],
         event_type: event_type,
         occurred_at: source["occurred_at"],
         captured_at: source["captured_at"],
         idempotency_key:
           Enum.join(
             ["openclaw", source["installation_id"], source["profile_id"], source["event_id"]],
             ":"
           ),
         payload_hash: EventEnvelope.payload_hash(payload),
         privacy: %{
           "filtered" => false,
           "filter_version" => "pending",
           "redaction_count" => 0,
           "private_blocks_removed" => 0
         },
         trace: %{},
         payload: payload
       }
       |> Map.reject(fn {_key, value} -> is_nil(value) end)}
    else
      {:error, :unsupported_hook} = error -> error
      _ -> {:error, {:malformed, [:payload]}}
    end
  end

  def normalize(_, _, _), do: {:error, {:malformed, [:payload]}}
end
