defmodule Backplane.Observability.Settings do
  @moduledoc """
  Typed Observability v2 policy accessors backed by `Backplane.Settings`.

  Invalid values retain the last known good configuration. When Settings is
  unavailable at boot, accessors fall back to safe compile-time defaults.
  """

  use GenServer

  alias Backplane.Observability.Buffer

  @table :backplane_observability_settings
  @pubsub Backplane.PubSub
  @topic "observability:settings:changed"

  @llm_enabled "observability.llm_proxy.enabled"
  @llm_persist "observability.llm_proxy.persist"
  @llm_retention_days "observability.llm_proxy.retention_days"
  @llm_payload_mode "observability.llm_proxy.payload_mode"
  @llm_sample_rate "observability.llm_proxy.sample_rate"

  @mcp_enabled "observability.mcp_proxy.enabled"
  @mcp_persist "observability.mcp_proxy.persist"
  @mcp_retention_days "observability.mcp_proxy.retention_days"
  @mcp_payload_mode "observability.mcp_proxy.payload_mode"
  @mcp_sample_rate "observability.mcp_proxy.sample_rate"

  @audit_enabled "observability.audit.enabled"
  @audit_retention_days "observability.audit.retention_days"

  @writer_batch_size "observability.writer.batch_size"
  @writer_flush_interval_ms "observability.writer.flush_interval_ms"
  @writer_queue_capacity "observability.writer.queue_capacity"

  @payload_modes ~w(none hash sampled full)
  @keys [
    @llm_enabled,
    @llm_persist,
    @llm_retention_days,
    @llm_payload_mode,
    @llm_sample_rate,
    @mcp_enabled,
    @mcp_persist,
    @mcp_retention_days,
    @mcp_payload_mode,
    @mcp_sample_rate,
    @audit_enabled,
    @audit_retention_days,
    @writer_batch_size,
    @writer_flush_interval_ms,
    @writer_queue_capacity
  ]

  @default_batch_sizes %{
    llm_proxy: 100,
    mcp_proxy_root: 200,
    mcp_tool_calls: 500,
    audit: 200
  }

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribe to validated observability policy changes."
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc "PubSub topic for validated observability policy changes."
  def topic, do: @topic

  @doc "Returns a snapshot of effective observability policy."
  @spec snapshot() :: map()
  def snapshot do
    %{
      llm_proxy: %{
        enabled: llm_proxy_enabled?(),
        persist: llm_proxy_persist?(),
        retention_days: llm_proxy_retention_days(),
        payload_mode: llm_proxy_payload_mode(),
        sample_rate: llm_proxy_sample_rate()
      },
      mcp_proxy: %{
        enabled: mcp_proxy_enabled?(),
        persist: mcp_proxy_persist?(),
        retention_days: mcp_proxy_retention_days(),
        payload_mode: mcp_proxy_payload_mode(),
        sample_rate: mcp_proxy_sample_rate()
      },
      audit: %{
        enabled: audit_enabled?(),
        retention_days: audit_retention_days()
      },
      writer: %{
        batch_size: writer_batch_size(),
        flush_interval_ms: writer_flush_interval_ms(),
        queue_capacity: writer_queue_capacity()
      }
    }
  end

  @spec llm_proxy_enabled?() :: boolean()
  def llm_proxy_enabled?, do: cached_boolean(@llm_enabled, true)

  @spec llm_proxy_persist?() :: boolean()
  def llm_proxy_persist?, do: cached_boolean(@llm_persist, true)

  @spec llm_proxy_retention_days() :: pos_integer()
  def llm_proxy_retention_days, do: cached_integer(@llm_retention_days, 90, 1, 3_660)

  @spec llm_proxy_payload_mode() :: String.t()
  def llm_proxy_payload_mode, do: cached_payload_mode(@llm_payload_mode, "none")

  @spec llm_proxy_sample_rate() :: float()
  def llm_proxy_sample_rate, do: cached_float(@llm_sample_rate, 1.0, 0.0, 1.0)

  @spec mcp_proxy_enabled?() :: boolean()
  def mcp_proxy_enabled?, do: cached_boolean(@mcp_enabled, true)

  @spec mcp_proxy_persist?() :: boolean()
  def mcp_proxy_persist?, do: cached_boolean(@mcp_persist, true)

  @spec mcp_proxy_retention_days() :: pos_integer()
  def mcp_proxy_retention_days, do: cached_integer(@mcp_retention_days, 30, 1, 3_660)

  @spec mcp_proxy_payload_mode() :: String.t()
  def mcp_proxy_payload_mode, do: cached_payload_mode(@mcp_payload_mode, "none")

  @spec mcp_proxy_sample_rate() :: float()
  def mcp_proxy_sample_rate, do: cached_float(@mcp_sample_rate, 1.0, 0.0, 1.0)

  @spec audit_enabled?() :: boolean()
  def audit_enabled?, do: cached_boolean(@audit_enabled, true)

  @spec audit_retention_days() :: pos_integer()
  def audit_retention_days, do: cached_integer(@audit_retention_days, 180, 1, 3_660)

  @spec writer_batch_size() :: pos_integer() | nil
  def writer_batch_size, do: cached_optional_integer(@writer_batch_size, 1, 5_000)

  @spec writer_batch_size(atom()) :: pos_integer()
  def writer_batch_size(domain) when is_atom(domain) do
    case writer_batch_size() do
      nil -> Map.fetch!(@default_batch_sizes, domain)
      value -> value
    end
  end

  @spec writer_flush_interval_ms() :: pos_integer()
  def writer_flush_interval_ms, do: cached_integer(@writer_flush_interval_ms, 250, 50, 60_000)

  @spec writer_queue_capacity() :: pos_integer() | nil
  def writer_queue_capacity, do: cached_optional_integer(@writer_queue_capacity, 100, 1_000_000)

  @spec queue_capacity(atom()) :: pos_integer()
  def queue_capacity(domain) when is_atom(domain) do
    case writer_queue_capacity() do
      nil -> Buffer.default_capacity(domain)
      value -> value
    end
  end

  @doc false
  @spec refresh_key(String.t()) :: :ok
  def refresh_key(key) when key in @keys do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:refresh, key})
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Enum.each(@keys, &refresh_cache(table, &1))
    maybe_subscribe_settings()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info({:setting_changed, key, _value}, state) when key in @keys do
    previous = cached_value(key)
    refresh_cache(state.table, key)
    current = cached_value(key)

    if current != previous do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:observability_setting_changed, key, current})
    end

    {:noreply, state}
  end

  def handle_info({:setting_changed, _key, _value}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:refresh, key}, state) do
    refresh_cache(state.table, key)
    {:noreply, state}
  end

  defp maybe_subscribe_settings do
    if Process.whereis(Backplane.Settings) do
      Backplane.Settings.subscribe()
    end
  end

  defp refresh_cache(table, key) do
    case validate(key, raw_value(key)) do
      {:ok, value} -> :ets.insert(table, {key, value})
      :invalid -> :ok
    end
  end

  defp cached_value(key) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _table ->
        case :ets.lookup(@table, key) do
          [{^key, value}] -> value
          [] -> nil
        end
    end
  end

  defp cached_boolean(key, default) do
    case cached_value(key) do
      value when is_boolean(value) -> value
      _ -> validated_or_default(key, default, &validate/2)
    end
  end

  defp cached_integer(key, default, _min, _max) do
    case cached_value(key) do
      value when is_integer(value) -> value
      _ -> validated_or_default(key, default, &validate/2)
    end
  end

  defp cached_optional_integer(key, _min, _max) do
    case cached_value(key) do
      value when is_integer(value) -> value
      _ ->
        case validate(key, raw_value(key)) do
          {:ok, value} -> value
          :invalid -> nil
        end
    end
  end

  defp cached_float(key, default, _min, _max) do
    case cached_value(key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value * 1.0
      _ -> validated_or_default(key, default, &validate/2)
    end
  end

  defp cached_payload_mode(key, default) do
    case cached_value(key) do
      value when value in @payload_modes -> value
      _ -> validated_or_default(key, default, &validate/2)
    end
  end

  defp validated_or_default(key, default, validator) do
    case validator.(key, raw_value(key)) do
      {:ok, value} ->
        if Process.whereis(__MODULE__) do
          :ets.insert(@table, {key, value})
        end

        value

      :invalid ->
        default
    end
  end

  defp raw_value(key) do
    if settings_available?() do
      Backplane.Settings.get(key)
    else
      Backplane.Settings.default_value(key)
    end
  end

  defp settings_available? do
    Process.whereis(Backplane.Settings) != nil
  end

  defp validate(@llm_enabled, value), do: validate_boolean(value)
  defp validate(@llm_persist, value), do: validate_boolean(value)
  defp validate(@mcp_enabled, value), do: validate_boolean(value)
  defp validate(@mcp_persist, value), do: validate_boolean(value)
  defp validate(@audit_enabled, value), do: validate_boolean(value)

  defp validate(@llm_retention_days, value), do: validate_integer(value, 1, 3_660)
  defp validate(@mcp_retention_days, value), do: validate_integer(value, 1, 3_660)
  defp validate(@audit_retention_days, value), do: validate_integer(value, 1, 3_660)

  defp validate(@writer_batch_size, nil), do: {:ok, nil}
  defp validate(@writer_queue_capacity, nil), do: {:ok, nil}
  defp validate(@writer_batch_size, value), do: validate_integer(value, 1, 5_000)
  defp validate(@writer_flush_interval_ms, value), do: validate_integer(value, 50, 60_000)
  defp validate(@writer_queue_capacity, value), do: validate_integer(value, 100, 1_000_000)

  defp validate(@llm_payload_mode, value), do: validate_payload_mode(value)
  defp validate(@mcp_payload_mode, value), do: validate_payload_mode(value)

  defp validate(@llm_sample_rate, value), do: validate_float(value, 0.0, 1.0)
  defp validate(@mcp_sample_rate, value), do: validate_float(value, 0.0, 1.0)

  defp validate(_key, _value), do: :invalid

  defp validate_boolean(value) when value in [true, false, "true", "false"] do
    {:ok, value == true or value == "true"}
  end

  defp validate_boolean(_value), do: :invalid

  defp validate_integer(value, min, max) when is_integer(value) and value >= min and value <= max do
    {:ok, value}
  end

  defp validate_integer(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> validate_integer(int, min, max)
      _ -> :invalid
    end
  end

  defp validate_integer(_value, _min, _max), do: :invalid

  defp validate_float(value, min, max) when is_float(value) and value >= min and value <= max do
    {:ok, value}
  end

  defp validate_float(value, min, max) when is_integer(value) do
    validate_float(value * 1.0, min, max)
  end

  defp validate_float(value, min, max) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> validate_float(float, min, max)
      _ -> :invalid
    end
  end

  defp validate_float(_value, _min, _max), do: :invalid

  defp validate_payload_mode(value) when value in @payload_modes, do: {:ok, value}
  defp validate_payload_mode(_value), do: :invalid
end
