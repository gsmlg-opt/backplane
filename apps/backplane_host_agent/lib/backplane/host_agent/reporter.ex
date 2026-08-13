defmodule Backplane.HostAgent.Reporter do
  @moduledoc """
  Formats host-agent status payloads for the Backplane host channel.
  """

  @agent_version "0.1.0"

  alias Backplane.HostAgent.Memory.{CaptureUploader, Spool}
  alias Backplane.HostAgent.Telemetry

  @doc "Builds the host-agent heartbeat payload."
  def heartbeat(config) do
    %{
      "agent_version" => @agent_version,
      "hostname" => hostname(),
      "machine_name" => Map.fetch!(config, :machine_name),
      "metadata" => %{"otp_release" => System.otp_release()},
      "capture" => capture_status(config),
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
      "capture" => config |> field(:capture) |> stringify_keys(),
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

  defp capture_status(config) do
    capture = field(config, :capture) || %{}

    if field(capture, :enabled) == false do
      capture_defaults("disabled")
    else
      spool_module = field(capture, :spool_module) || Spool.Turso
      spool = field(capture, :spool) || field(capture, :spool_name) || Spool.Turso
      uploader_module = field(capture, :uploader_module) || CaptureUploader
      uploader = field(capture, :uploader) || field(capture, :uploader_name) || CaptureUploader
      stats = safe_capture_call(fn -> spool_module.stats(spool) end, nil)
      uploader_status = safe_capture_call(fn -> uploader_module.status(uploader) end, nil)

      capture_defaults(capture_connection_state(uploader_status))
      |> Map.merge(spool_metrics(stats))
      |> Map.merge(uploader_metrics(uploader_status))
    end
  end

  defp capture_connection_state(status) when is_map(status),
    do: to_string(status[:connection_state] || "disconnected")

  defp capture_connection_state(_status), do: "disconnected"

  defp spool_metrics(stats) when is_map(stats) do
    %{
      "spool_depth" => stats[:pending_depth] || 0,
      "spool_bytes" => stats[:pending_bytes] || 0,
      "oldest_event_age_ms" => Telemetry.oldest_age_ms(stats[:oldest_occurred_at]),
      "age_warning" => stats[:age_warning] || false,
      "captured_count" => stats[:captured_count] || 0,
      "redacted_count" => stats[:redacted_count] || 0,
      "rejected_count" => stats[:rejected_count] || 0,
      "retry_count" => stats[:retry_count] || 0,
      "dead_letter_count" => stats[:dead_letter_count] || 0
    }
  end

  defp spool_metrics(_stats) do
    Map.new(
      ~w(spool_depth spool_bytes oldest_event_age_ms age_warning captured_count redacted_count rejected_count retry_count dead_letter_count),
      &{&1, nil}
    )
  end

  defp uploader_metrics(status) when is_map(status) do
    %{
      "upload_latency_ms" => status[:upload_latency_ms],
      "ack_latency_ms" => status[:ack_latency_ms]
    }
  end

  defp uploader_metrics(_status),
    do: %{"upload_latency_ms" => nil, "ack_latency_ms" => nil}

  defp capture_defaults(connection_state) do
    %{
      "connection_state" => connection_state,
      "spool_depth" => 0,
      "spool_bytes" => 0,
      "oldest_event_age_ms" => 0,
      "age_warning" => false,
      "captured_count" => 0,
      "redacted_count" => 0,
      "rejected_count" => 0,
      "retry_count" => 0,
      "dead_letter_count" => 0,
      "upload_latency_ms" => nil,
      "ack_latency_ms" => nil
    }
  end

  defp safe_capture_call(callback, default) do
    case callback.() do
      result when is_map(result) -> result
      _ -> default
    end
  rescue
    _error -> default
  catch
    :exit, _reason -> default
  end

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
