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
    # LLM auto model target preferences
    "llm.auto_models.fast.targets" => %{
      value: [],
      type: "json",
      desc: "Preferred target model ids for the fast auto model"
    },
    "llm.auto_models.smart.targets" => %{
      value: [],
      type: "json",
      desc: "Preferred target model ids for the smart auto model"
    },
    "llm.auto_models.expert.targets" => %{
      value: [],
      type: "json",
      desc: "Preferred target model ids for the expert auto model"
    },
    "llm.model_aliases.custom" => %{
      value: %{},
      type: "json",
      desc: "Custom one-to-one model aliases"
    },
    # Managed Services
    "services.day.enabled" => %{
      value: true,
      type: "boolean",
      desc: "Enable day_ex datetime service"
    },
    "services.web.enabled" => %{
      value: true,
      type: "boolean",
      desc: "Enable web fetch service"
    },
    # Skill archive storage
    "skills.archive.max_bytes" => %{
      value: 20_000_000,
      type: "integer",
      desc: "Maximum uploaded skill archive size in bytes"
    },
    "skills.archive.max_files" => %{
      value: 500,
      type: "integer",
      desc: "Maximum file count in an uploaded skill archive"
    },
    "skills.blob.local_root" => %{
      value: nil,
      type: "string",
      desc: "Optional local filesystem root for skill archive blobs"
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

  @doc "List all setting definitions with metadata."
  @spec list_definitions() :: [map()]
  def list_definitions, do: []

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
