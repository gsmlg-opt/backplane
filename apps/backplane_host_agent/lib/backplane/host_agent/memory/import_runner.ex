defmodule Backplane.HostAgent.Memory.ImportRunner do
  @moduledoc "Runs an accepted replay import through durable capture and lifecycle reporting."

  alias Backplane.HostAgent.Channel
  alias Backplane.HostAgent.Memory.{CaptureUploader, Import}
  alias Backplane.HostAgent.Memory.Import.Protocol

  def run(path, import_opts, runtime_opts) when is_binary(path) and is_list(import_opts) do
    request_id = Keyword.get(runtime_opts, :request_id)
    channel = Keyword.fetch!(runtime_opts, :channel)
    channel_module = Keyword.get(runtime_opts, :channel_module, Channel)
    import_module = Keyword.get(runtime_opts, :import_module, Import)
    uploader_module = Keyword.get(runtime_opts, :uploader_module, CaptureUploader)
    upload_limit = Keyword.fetch!(runtime_opts, :upload_limit)
    lifecycle_ref = make_ref()

    reporter = fn payload ->
      payload = maybe_put(payload, "request_id", request_id)

      with :ok <- maybe_drain(payload, uploader_module, runtime_opts, upload_limit),
           :ok <- Protocol.report(channel, payload, channel_module: channel_module) do
        send(self(), {lifecycle_ref, payload["action"]})
        :ok
      end
    end

    result = import_module.run(path, Keyword.put(import_opts, :reporter, reporter))

    case result do
      {:error, _reason} = error ->
        ensure_failed_lifecycle(path, import_opts, lifecycle_ref, reporter)
        error

      other ->
        other
    end
  end

  defp maybe_drain(%{"action" => "completed"}, uploader_module, opts, limit) do
    drain(uploader_module, opts, limit)
  end

  defp maybe_drain(_payload, _uploader_module, _opts, _limit), do: :ok

  defp drain(_uploader_module, _opts, 0), do: {:error, :import_upload_limit_exceeded}

  defp drain(uploader_module, opts, remaining) do
    case uploader_module.drain_once(
           spool: Keyword.fetch!(opts, :spool),
           spool_module: Keyword.fetch!(opts, :spool_module),
           channel: Keyword.fetch!(opts, :channel),
           channel_module: Keyword.get(opts, :channel_module, Channel),
           host_id: Keyword.fetch!(opts, :host_id)
         ) do
      {:ok, %{"status" => "empty"}} -> :ok
      {:ok, _summary} -> drain(uploader_module, opts, remaining - 1)
      {:error, reason} -> {:error, {:import_upload_failed, reason}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_failed_lifecycle(path, import_opts, lifecycle_ref, reporter) do
    unless reported?(lifecycle_ref, "started") do
      batch_id = Keyword.fetch!(import_opts, :batch_id)

      started = %{
        "protocol" => "host_import.v1",
        "action" => "started",
        "batch_id" => batch_id,
        "integration" => "claude_code",
        "source_format" => "claude_code_jsonl",
        "source_path_fingerprint" => path_fingerprint(path, import_opts)
      }

      failed = %{
        "protocol" => "host_import.v1",
        "action" => "failed",
        "batch_id" => batch_id,
        "discovered_count" => 0,
        "imported_count" => 0,
        "duplicate_count" => 0,
        "rejected_count" => 0,
        "error" => "import_failed"
      }

      with :ok <- reporter.(started), do: reporter.(failed)
    end

    :ok
  end

  defp reported?(ref, action) do
    receive do
      {^ref, ^action} -> true
    after
      0 -> false
    end
  end

  defp path_fingerprint(path, import_opts) do
    target = Path.expand(path)

    root =
      import_opts
      |> Keyword.fetch!(:approved_roots)
      |> Enum.map(&Path.expand/1)
      |> Enum.find(fn candidate ->
        target == candidate or String.starts_with?(target, candidate <> "/")
      end)

    source = if root, do: root <> "\0" <> Path.relative_to(target, root), else: target
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, source), case: :lower)
  end
end
