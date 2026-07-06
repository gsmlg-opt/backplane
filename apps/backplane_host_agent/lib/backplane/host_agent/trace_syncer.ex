defmodule Backplane.HostAgent.TraceSyncer do
  @moduledoc """
  Store-and-forward syncer for host-agent trace JSONL files.
  """

  use GenServer

  alias Backplane.HostAgent.{Channel, MemoryProxy}

  @protocol "host_trace.v1"
  @default_batch_size 100
  @default_interval_ms 10_000

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @impl true
  def init(opts) do
    state = normalize_opts(opts)
    File.mkdir_p!(state.dir)
    schedule_drain(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:drain, state) do
    _ = drain_once(state)
    schedule_drain(state)
    {:noreply, state}
  end

  @doc "Drains one batch of trace items if a channel is available."
  def drain_once(opts \\ []) do
    opts = normalize_opts(opts)
    cursor = load_cursor(opts.dir)
    items = read_items(opts.dir, cursor, opts.batch_size)

    cond do
      items == [] ->
        {:ok, %{"drained" => 0}}

      true ->
        with {:ok, channel} <- connected_channel(opts) do
          payload = %{"protocol" => @protocol, "items" => items}

          case push_sync(opts.channel_module, channel, payload) do
            {:ok, %{"ok" => true, "result" => %{"items" => ack_items}}} ->
              advance_cursor(opts.dir, cursor, ack_items)
              {:ok, %{"drained" => length(items)}}

            {:ok, %{"items" => ack_items}} ->
              advance_cursor(opts.dir, cursor, ack_items)
              {:ok, %{"drained" => length(items)}}

            {:ok, _reply} ->
              {:error, :invalid_ack}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :not_connected} -> {:ok, %{"drained" => 0, "status" => "disconnected"}}
        end
    end
  end

  defp advance_cursor(dir, cursor, ack_items) do
    acked =
      ack_items
      |> Enum.filter(&(&1["status"] == "ok"))
      |> MapSet.new(& &1["seq"])

    next_cursor = highest_contiguous(cursor, acked)

    if next_cursor > cursor do
      persist_cursor(dir, next_cursor)
    end

    next_cursor
  end

  defp highest_contiguous(cursor, acked) do
    next = cursor + 1

    if MapSet.member?(acked, next) do
      highest_contiguous(next, acked)
    else
      cursor
    end
  end

  defp read_items(dir, cursor, batch_size) do
    dir
    |> trace_files()
    |> Stream.flat_map(&File.stream!(&1, :line, []))
    |> Stream.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"seq" => seq} = item} when is_integer(seq) and seq > cursor -> [item]
        _ -> []
      end
    end)
    |> Enum.take(batch_size)
  rescue
    _error -> []
  end

  defp push_sync(channel_module, channel, payload) do
    channel_module.push(channel, "trace_sync", payload)
  catch
    :exit, reason -> {:error, reason}
  end

  defp connected_channel(%{channel: channel}) when is_pid(channel), do: {:ok, channel}

  defp connected_channel(%{channel_provider: channel_provider}) do
    if function_exported?(channel_provider, :channel, 0) do
      case channel_provider.channel() do
        channel when is_pid(channel) -> {:ok, channel}
        _ -> {:error, :not_connected}
      end
    else
      {:error, :not_connected}
    end
  end

  defp normalize_opts(opts) when is_list(opts) do
    config =
      Keyword.get(
        opts,
        :config,
        Application.get_env(:backplane_host_agent, :telemetry_config, %{})
      )

    %{
      dir: Keyword.get(opts, :dir, config_value(config, :dir)),
      channel: Keyword.get(opts, :channel),
      channel_module: Keyword.get(opts, :channel_module, Channel),
      channel_provider: Keyword.get(opts, :channel_provider, MemoryProxy),
      batch_size:
        Keyword.get(
          opts,
          :batch_size,
          config_value(config, :sync_batch_size) || @default_batch_size
        ),
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          config_value(config, :sync_interval_ms) || @default_interval_ms
        )
    }
  end

  defp normalize_opts(%{} = opts) do
    opts
    |> Map.to_list()
    |> normalize_opts()
  end

  defp schedule_drain(%{interval_ms: interval_ms})
       when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :drain, interval_ms)
  end

  defp schedule_drain(_state), do: :ok

  defp load_cursor(dir) do
    case File.read(cursor_file(dir)) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"seq" => seq}} when is_integer(seq) and seq >= 0 -> seq
          _ -> 0
        end

      {:error, _reason} ->
        0
    end
  end

  defp persist_cursor(dir, seq) do
    File.write!(cursor_file(dir), Jason.encode!(%{"seq" => seq}))
  end

  defp cursor_file(dir), do: Path.join(dir, "cursor.json")

  defp trace_files(dir) do
    dir
    |> Path.join("traces-*.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key)))
  end

  defp config_value(_config, _key), do: nil
end
