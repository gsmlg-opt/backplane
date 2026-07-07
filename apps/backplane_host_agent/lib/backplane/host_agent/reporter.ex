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

  @doc "Builds the host-agent config report payload."
  def config_report(config) do
    %{
      "agent" =>
        compact(%{
          "host_id" => field(config, :host_id),
          "machine_name" => field(config, :machine_name),
          "hub_url" => field(config, :hub_url),
          "token" => redacted_token(field(config, :token)),
          "interval_ms" => field(config, :interval_ms),
          "manifest_path" => field(config, :manifest_path),
          "work_dir" => field(config, :work_dir),
          "http_bind" => field(config, :http_bind),
          "http_port" => field(config, :http_port)
        }),
      "memory" => config |> field(:memory) |> stringify_keys(),
      "telemetry" => config |> field(:telemetry) |> stringify_keys(),
      "targets" => config |> field(:targets) |> List.wrap() |> Enum.map(&stringify_keys/1)
    }
  end

  @doc "Builds a host-agent sync result payload."
  def sync_result(status, results) do
    sync_result(status, results, DateTime.utc_now())
  end

  def sync_result(status, results, started_at) do
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

  defp field(map, key) when is_map(map) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      Map.get(map, to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp redacted_token(nil), do: nil
  defp redacted_token(""), do: ""
  defp redacted_token(_token), do: "REDACTED"

  defp compact(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(nil), do: %{}
  defp stringify_keys(value), do: value
end
