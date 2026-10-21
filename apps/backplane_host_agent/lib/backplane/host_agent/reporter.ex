defmodule Backplane.HostAgent.Reporter do
  @moduledoc """
  Formats host-agent status payloads for the Backplane host channel.
  """

  @agent_version "0.1.0"

  alias Backplane.HostAgent.Memory.{CaptureUploader, Diagnostics, Spool}
  alias Backplane.HostAgent.Telemetry

  @doc "Builds the host-agent heartbeat payload."
  def heartbeat(config) do
    %{
      "agent_version" => @agent_version,
      "hostname" => hostname(),
      "machine_name" => Map.fetch!(config, :machine_name),
      "metadata" => %{"otp_release" => System.otp_release()},
      "capture" => capture_status(config),
      "memory" => memory_status(config),
      "targets" => Enum.map(Map.get(config, :targets, []), &stringify_keys/1)
    }
  end

  @doc "Builds the host-agent config report payload."
  def config_report(config, context \\ %{}) do
    %{
      "agent" =>
        compact(%{
          "host_id" => field(config, :host_id),
          "machine_name" => field(config, :machine_name),
          "hub_url" => safe_hub_url(field(config, :hub_url)),
          "token" => redacted_token(field(config, :token)),
          "interval_ms" => field(config, :interval_ms),
          "manifest_path" => field(config, :manifest_path),
          "work_dir" => field(config, :work_dir),
          "http_bind" => field(config, :http_bind),
          "http_port" => field(config, :http_port)
        }),
      "local_settings_applied_at" => Map.get(context, :local_settings_applied_at),
      "memory_negotiation" => negotiation_report(Map.get(context, :memory_negotiation_report)),
      "memory" => memory_settings(field(config, :memory)),
      "capture" =>
        safe_settings(
          field(config, :capture),
          ~w(enabled db_path inject_context context_timeout_ms recall_cache_max_entries recall_cache_max_bytes recall_cache_ttl_ms upload_interval_ms batch_size batch_bytes spool_max_bytes spool_max_age_days retry_base_ms retry_max_ms compaction_batch_size)
        ),
      "telemetry" =>
        safe_settings(
          field(config, :telemetry),
          ~w(enabled dir sync_interval_ms sync_batch_size retention_days)
        ),
      "targets" =>
        config
        |> field(:targets)
        |> List.wrap()
        |> Enum.take(50)
        |> Enum.map(&safe_settings(&1, ~w(name runtime path enabled)))
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

  defp memory_status(config) do
    memory = field(config, :memory) || %{}
    diagnostics = field(memory, :diagnostics_module) || Diagnostics
    opts = field(memory, :diagnostics_opts) || []

    case safe_capture_call(fn -> diagnostics.snapshot(opts) end, nil) do
      {:ok, %{"edge" => edge, "outbox" => outbox} = snapshot}
      when is_map(edge) and is_map(outbox) ->
        measured =
          if edge["status"] == "available",
            do:
              Map.take(
                edge,
                ~w(status protection_mode items bytes revision lag lag_status stale_age_seconds)
              ),
            else: %{}

        memory_defaults()
        |> Map.merge(measured)
        |> Map.put("protection_mode", edge["protection_mode"] || "disabled")
        |> Map.put(
          "pending_commands",
          Enum.sum(Enum.map(~w(pending inflight retry_wait), &Map.get(outbox, &1, 0)))
        )
        |> Map.put("failed_commands", Map.get(outbox, "dead_letter", 0))
        |> Map.put("retry_count", Map.get(outbox, "retry_wait", 0))
        |> Map.put("dead_letter_count", Map.get(outbox, "dead_letter", 0))
        |> Map.put("last_successful_sync", snapshot["last_successful_sync"])
        |> Map.put(
          "partitions",
          edge
          |> Map.get("partitions", [])
          |> Enum.take(50)
          |> Enum.map(
            &Map.take(
              &1,
              ~w(memory_space_id scope namespace applied_revision last_sync_at stale_age_seconds)
            )
          )
        )

      _ ->
        memory_defaults()
    end
  end

  defp memory_defaults do
    Map.new(
      ~w(items bytes revision lag stale_age_seconds retry_count dead_letter_count pending_commands failed_commands last_successful_sync),
      &{&1, nil}
    )
    |> Map.merge(%{
      "status" => "unavailable",
      "protection_mode" => "disabled",
      "lag_status" => "unavailable",
      "partitions" => []
    })
  end

  defp safe_settings(config, keys) do
    config
    |> stringify_keys()
    |> Map.take(keys)
    |> Map.filter(fn {_key, value} ->
      is_boolean(value) or is_integer(value) or (is_binary(value) and byte_size(value) <= 4096)
    end)
  end

  defp safe_hub_url(nil), do: nil

  defp safe_hub_url(value) when is_binary(value) do
    value
    |> URI.parse()
    |> Map.merge(%{userinfo: nil, query: nil, fragment: nil})
    |> URI.to_string()
  end

  defp memory_settings(memory) do
    safe_settings(
      memory,
      ~w(enabled db_path bound_scope local_ttl_days sync_interval_ms sync_batch_size max_attempts tombstone_relearn)
    )
    |> Map.put("host_sync_v1", safe_settings(field(memory, :host_sync_v1), ~w(enabled)))
    |> Map.put(
      "host_sync_v2",
      safe_settings(
        field(memory, :host_sync_v2),
        ~w(enabled development_plaintext db_path max_frame_bytes max_changes max_items max_bytes max_items_per_partition max_age_days sync_interval_ms)
      )
    )
  end

  defp negotiation_report(nil), do: nil

  defp negotiation_report(report) when is_map(report) do
    report = stringify_keys(report)

    report
    |> Map.take(~w(selected applied_at))
    |> Map.put(
      "partitions",
      report
      |> Map.get("partitions", [])
      |> Enum.take(50)
      |> Enum.map(&Map.take(&1, ~w(memory_space_id scope namespace)))
    )
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
      {:ok, result} when is_map(result) -> {:ok, result}
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
