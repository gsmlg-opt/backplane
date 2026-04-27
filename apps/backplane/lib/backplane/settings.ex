defmodule Backplane.Settings do
  @moduledoc """
  Runtime configuration layer. Settings stored in system_settings table,
  cached in ETS, broadcast via PubSub on change.

  - `get/1` reads from ETS (fast path)
  - `set/2` writes to DB, updates ETS, broadcasts change
  """

  use GenServer

  require Logger

  alias Backplane.Repo
  alias Backplane.Settings.Setting

  import Ecto.Query

  @table :backplane_settings
  @pubsub Backplane.PubSub
  @topic "settings:changed"

  # --- Defaults ---

  @defaults %{
    # General
    "instance.name" => %{
      value: "Backplane",
      type: "string",
      desc: "Display name in UI and MCP server info"
    },
    "admin.auth_enabled" => %{value: false, type: "boolean", desc: "Require auth for admin UI"},
    "admin.username" => %{value: "admin", type: "string", desc: "Admin UI username"},
    "admin.password_hash" => %{value: nil, type: "string", desc: "Bcrypt hash of admin password"},
    # MCP Hub
    "mcp.auth_required" => %{
      value: false,
      type: "boolean",
      desc: "Require bearer token for MCP endpoint"
    },
    "mcp.default_timeout_ms" => %{
      value: 30_000,
      type: "integer",
      desc: "Default upstream tool call timeout"
    },
    "mcp.tool_discovery_interval_ms" => %{
      value: 300_000,
      type: "integer",
      desc: "Tool discovery refresh interval"
    },
    # LLM Proxy
    "llm.default_rpm_limit" => %{
      value: nil,
      type: "integer",
      desc: "Fallback RPM limit when provider has none"
    },
    "llm.usage_retention_days" => %{
      value: 90,
      type: "integer",
      desc: "How long to keep usage logs"
    },
    "llm.health_check_interval_s" => %{
      value: 60,
      type: "integer",
      desc: "Seconds between health probes"
    },
    "llm.streaming_enabled" => %{value: true, type: "boolean", desc: "Allow streaming responses"},
    # Managed Services
    "services.skills.enabled" => %{
      value: true,
      type: "boolean",
      desc: "Enable skills managed service"
    },
    "services.skills.max_upload_bytes" => %{
      value: 1_048_576,
      type: "integer",
      desc: "Max skill upload size (1MB)"
    },
    "services.day.enabled" => %{
      value: true,
      type: "boolean",
      desc: "Enable day_ex datetime service"
    },
    "services.web.enabled" => %{value: true, type: "boolean", desc: "Enable web fetch service"},
    # Observability
    "audit.enabled" => %{value: true, type: "boolean", desc: "Enable tool call audit logging"},
    "audit.retention_days" => %{value: 30, type: "integer", desc: "Audit log retention"},
    "metrics.enabled" => %{
      value: true,
      type: "boolean",
      desc: "Enable Prometheus metrics endpoint"
    }
  }

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a setting value by key. Reads from ETS (fast)."
  @spec get(String.t()) :: term()
  def get(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> get_default(key)
    end
  end

  @doc "Set a setting value. Writes to DB, updates ETS, broadcasts."
  @spec set(String.t(), term()) :: :ok | {:error, term()}
  def set(key, value) when is_binary(key) do
    GenServer.call(__MODULE__, {:set, key, value})
  end

  @doc "Get all settings as a map."
  @spec all() :: map()
  def all do
    @table
    |> :ets.tab2list()
    |> Map.new()
  end

  @sensitive_keys ~w(admin.password_hash)

  @doc "List all setting definitions with metadata."
  @spec list_definitions() :: [map()]
  def list_definitions do
    @defaults
    |> Enum.reject(fn {key, _} -> key in @sensitive_keys end)
    |> Enum.map(fn {key, meta} ->
      %{
        key: key,
        value: get(key),
        value_type: meta.type,
        description: meta.desc
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc "Subscribe to setting changes."
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc "The PubSub topic for setting changes."
  def topic, do: @topic

  # --- Server ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    send(self(), :seed_and_load)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:seed_and_load, state) do
    seed_defaults()
    load_all()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call({:set, key, value}, _from, state) do
    wrapped = %{"v" => value}
    now = DateTime.utc_now()
    type = get_in(@defaults, [key, :type]) || "string"
    desc = get_in(@defaults, [key, :desc])

    result =
      case Repo.get(Setting, key) do
        nil ->
          %Setting{}
          |> Setting.changeset(%{key: key, value: wrapped, value_type: type, description: desc})
          |> Map.put(:action, :insert)
          |> Repo.insert()

        existing ->
          existing
          |> Ecto.Changeset.change(value: wrapped, updated_at: now)
          |> Repo.update()
      end

    case result do
      {:ok, _} ->
        :ets.insert(@table, {key, value})
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:setting_changed, key, value})
        {:reply, :ok, state}

      {:error, changeset} ->
        {:reply, {:error, changeset}, state}
    end
  end

  # --- Private ---

  defp seed_defaults do
    for {key, meta} <- @defaults do
      unless Repo.get(Setting, key) do
        %Setting{}
        |> Setting.changeset(%{
          key: key,
          value: %{"v" => meta.value},
          value_type: meta.type,
          description: meta.desc
        })
        |> Map.put(:action, :insert)
        |> Repo.insert()
      end
    end

    Logger.debug("Settings: seeded #{map_size(@defaults)} defaults")
  rescue
    e ->
      Logger.warning("Settings: seed failed: #{Exception.message(e)}")
  end

  defp load_all do
    settings = Repo.all(from(s in Setting, select: {s.key, s.value}))

    for {key, wrapped} <- settings do
      value = unwrap(wrapped)
      :ets.insert(@table, {key, value})
    end

    Logger.debug("Settings: loaded #{length(settings)} settings into ETS")
  rescue
    e ->
      Logger.warning("Settings: load failed: #{Exception.message(e)}")
  end

  defp unwrap(%{"v" => value}), do: value
  defp unwrap(other), do: other

  defp get_default(key) do
    case Map.get(@defaults, key) do
      %{value: value} -> value
      nil -> nil
    end
  end
end
