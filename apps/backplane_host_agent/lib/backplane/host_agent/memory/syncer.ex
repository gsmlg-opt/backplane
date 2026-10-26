defmodule Backplane.HostAgent.Memory.Syncer do
  @moduledoc "Drains immutable, authority-bound memory_commands.v2 outbox rows."
  use GenServer

  alias Backplane.HostAgent.{Channel, Memory, MemoryProxy}
  alias Backplane.HostAgent.Memory.{Access, Store}

  @default_batch_size 50
  @max_batch_size 50
  @default_interval_ms 5_000
  @default_max_attempts 5

  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = normalize_opts(opts)
    schedule_drain(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:drain, state) do
    _ = drain_once(state)
    schedule_drain(state)
    {:noreply, state}
  end

  @doc "Drains only negotiated commands; unavailable authority never selects another writer."
  def drain_once(opts \\ []) do
    case drain_shared(opts) do
      {:ok, %{drained: count}} ->
        {:ok, %{"drained" => count, "protocol" => "memory_commands.v2"}}

      {:error, reason}
      when reason in [:access_owner_unavailable, :unauthorized, :not_connected] ->
        {:ok, %{"drained" => 0, "status" => "awaiting_authority"}}

      error ->
        error
    end
  end

  @doc false
  def drain_shared(opts \\ []) do
    opts = normalize_opts(opts)

    with {:ok, fallback_channel} <- connected_channel(opts),
         {:ok, batch} <-
           Access.run_local(
             :all,
             :drain,
             fn context ->
               with {:ok, channel} <- live_channel(context.channel || fallback_channel),
                    {:ok, rows} <-
                      if(context.store == opts.store,
                        do: Memory.shared_claim(context, now(opts), opts.max_attempts),
                        else: {:ok, []}
                      ) do
                 {:ok,
                  %{
                    rows: rows,
                    generation: context.generation,
                    channel: channel
                  }}
               end
             end,
             opts.access_server
           ) do
      if batch.rows == [] do
        {:ok, %{drained: 0}}
      else
        payload = %{
          "protocol" => "memory_commands.v2",
          "items" => Enum.map(batch.rows, &Jason.decode!(&1["payload"]))
        }

        reply = push_sync(opts.channel_module, batch.channel, payload)

        if credential_rejection?(reply) do
          {:error, reason} = reply

          Backplane.HostAgent.MemoryProxy.retain_credential_rejection(
            reason,
            batch.channel,
            batch.generation
          )

          Access.fence(:all, :connection_rejected, batch.generation, opts.access_server)
        end

        result =
          Access.run_local(
            :all,
            :settle,
            &Memory.shared_settle(&1, batch.rows, reply, now(opts), opts.max_attempts),
            opts.access_server
          )

        if result == {:error, :invalid_ack} do
          _ =
            Access.run_local(
              :all,
              :settle,
              &Memory.shared_settle(
                &1,
                batch.rows,
                {:error, :invalid_protocol},
                now(opts),
                opts.max_attempts
              ),
              opts.access_server
            )
        end

        result
      end
    end
  end

  defp credential_rejection?({:error, %{"code" => "unauthorized", "retryable" => false}}),
    do: true

  defp credential_rejection?(_), do: false

  defp push_sync(channel_module, channel, payload) do
    channel_module.push(channel, "memory_sync", payload)
  catch
    :exit, reason -> {:error, {:channel_exit, reason}}
  end

  defp connected_channel(%{channel: channel}) when is_pid(channel), do: live_channel(channel)

  defp connected_channel(%{channel_provider: channel_provider}) do
    if function_exported?(channel_provider, :channel, 0) do
      live_channel(channel_provider.channel())
    else
      {:error, :not_connected}
    end
  end

  # An unavailable channel is not a delivery attempt. Once admitted, failures
  # during push still settle through the normal bounded transport retry path.
  defp live_channel(channel) when is_pid(channel) do
    if Process.alive?(channel), do: {:ok, channel}, else: {:error, :not_connected}
  end

  defp live_channel(_channel), do: {:error, :not_connected}

  defp normalize_opts(opts) when is_list(opts) do
    config =
      Keyword.get(opts, :config, Application.get_env(:backplane_host_agent, :memory_config, %{}))

    %{
      store:
        Keyword.get(
          opts,
          :store,
          Application.get_env(:backplane_host_agent, :memory_store, Store)
        ),
      config: config,
      access_server: Keyword.get(opts, :access_server, Access),
      channel: Keyword.get(opts, :channel),
      channel_module: Keyword.get(opts, :channel_module, Channel),
      channel_provider: Keyword.get(opts, :channel_provider, MemoryProxy),
      batch_size:
        opts
        |> Keyword.get(:batch_size, config_value(config, :sync_batch_size) || @default_batch_size)
        |> clamp_batch_size(),
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          config_value(config, :sync_interval_ms) || @default_interval_ms
        ),
      max_attempts:
        Keyword.get(
          opts,
          :max_attempts,
          config_value(config, :max_attempts) || @default_max_attempts
        ),
      now_fun: Keyword.get(opts, :now_fun, &timestamp/0),
      jitter_fun: Keyword.get(opts, :jitter_fun, &:rand.uniform/0)
    }
  end

  defp normalize_opts(%{} = opts) do
    opts
    |> Map.to_list()
    |> normalize_opts()
  end

  defp clamp_batch_size(value) when is_integer(value), do: min(max(value, 1), @max_batch_size)
  defp clamp_batch_size(_value), do: @default_batch_size

  defp schedule_drain(%{interval_ms: interval_ms})
       when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :drain, interval_ms)
  end

  defp schedule_drain(_state), do: :ok

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key)))
  end

  defp config_value(_config, _key), do: nil

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp now(%{now_fun: fun}), do: fun.()
end
