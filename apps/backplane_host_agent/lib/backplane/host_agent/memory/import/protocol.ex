defmodule Backplane.HostAgent.Memory.Import.Protocol do
  @moduledoc "Remote-safe host channel protocol for import batch lifecycle audit."

  alias Backplane.HostAgent.Channel

  def report(channel, payload, opts \\ []) when is_pid(channel) and is_map(payload) do
    channel_module = Keyword.get(opts, :channel_module, Channel)

    case channel_module.push(channel, "memory_import_batch", payload) do
      {:ok, %{"ok" => true}} -> :ok
      {:ok, reply} -> {:error, {:invalid_import_reply, reply}}
      {:error, reason} -> {:error, {:import_report_failed, reason}}
    end
  rescue
    error -> {:error, {:import_report_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:import_report_failed, reason}}
  end
end
