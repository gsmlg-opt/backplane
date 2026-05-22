defmodule Backplane.HostAgent.Reporter do
  @moduledoc """
  Formats host-agent status payloads for the Backplane host channel.
  """

  @agent_version "0.1.0"

  @doc "Builds the host-agent heartbeat payload."
  def heartbeat(config) do
    %{
      "agent_version" => @agent_version,
      "hostname" => hostname(),
      "machine_name" => Map.fetch!(config, :machine_name),
      "metadata" => %{"otp_release" => System.otp_release()},
      "targets" => Enum.map(Map.get(config, :targets, []), &stringify_keys/1)
    }
  end

  @doc "Builds a host-agent sync result payload."
  def sync_result(status, results) do
    started_at = DateTime.utc_now()
    finished_at = DateTime.utc_now()

    %{
      "finished_at" => DateTime.to_iso8601(finished_at),
      "results" => Enum.map(results, &stringify_keys/1),
      "started_at" => DateTime.to_iso8601(started_at),
      "status" => to_string(status)
    }
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      {:error, _reason} -> "unknown"
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
