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
    # Skills Hub
    "skills.archive.max_bytes" => %{
      value: 20_000_000,
      type: "integer",
      desc: "Maximum uploaded skill archive size in bytes"
    },
    "skills.archive.max_files" => %{
      value: 500,
      type: "integer",
      desc: "Maximum uploaded skill archive file count"
    },
    "skills.blob.local_root" => %{
      value: nil,
      type: "string",
      desc: "Local filesystem root for skill archive blob storage"
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
    # Memory V2 rollout controls
    "memory.pipeline.enabled" => %{
      value: false,
      type: "boolean",
      desc: "Enable the Memory V2 pipeline master gate"
    },
    "memory.events.enabled" => %{
      value: false,
      type: "boolean",
      desc: "Enable authoritative Memory V2 event ingestion"
    },
    "memory.events.dual_write" => %{
      value: false,
      type: "boolean",
      desc: "Enable atomic Memory V2 event and observation dual-write"
    },
    "memory.window_summaries.enabled" => %{
      value: false,
      type: "boolean",
      desc: "Enable Memory V2 window summaries"
    },
    "memory.session_summary_v2.enabled" => %{
      value: false,
      type: "boolean",
      desc: "Enable Memory V2 session summary generation"
    },
    "memory.fact_extraction_v2.enabled" => %{
      value: false,
      type: "boolean",
      desc: "Enable Memory V2 fact extraction"
    },
    "memory.procedure_extraction_v2.enabled" => %{
      value: false,
      type: "boolean",
      desc: "Enable Memory V2 procedure extraction"
    },
    "memory.relation_classifier.enabled" => %{
      value: false,
      type: "boolean",
      desc: "Enable automatic Memory V2 relation classification"
    },
    "memory.recall_v2.enabled" => %{
      value: false,
      type: "boolean",
      desc: "Enable Memory V2 recall"
    },
    "memory.recall_trace_enabled" => %{
      value: true,
      type: "boolean",
      desc: "Persist privacy-filtered Recall V2 traces"
    },
    "memory.recall_trace_retention_days" => %{
      value: 30,
      type: "integer",
      desc: "Recall trace retention in days (allowed range 1..3660)"
    },
    "memory.recall_rrf_k" => %{
      value: 60,
      type: "integer",
      desc: "Weighted reciprocal-rank-fusion constant (allowed range 1..1000)"
    },
    "memory.recall_channel_weights" => %{
      value: %{"fts" => 1.0, "vector" => 1.0, "graph" => 1.0},
      type: "json",
      desc: "Recall V2 FTS, vector, and graph fusion weights (each allowed range 0..100)"
    },
    "memory.recall_channel_limits" => %{
      value: %{"fts" => 50, "vector" => 50, "graph" => 50},
      type: "json",
      desc: "Recall V2 per-channel candidate limits (each allowed range 1..500)"
    },
    "memory.recall_max_per_session" => %{
      value: 3,
      type: "integer",
      desc: "Recall diversity maximum per source session (allowed range 1..100)"
    },
    "memory.recall_token_budget" => %{
      value: 4_096,
      type: "integer",
      desc: "Default Recall V2 context token budget (allowed range 1..100000)"
    },
    "memory.recall_reranker_enabled" => %{
      value: false,
      type: "boolean",
      desc: "Enable optional Recall V2 top-K reranking"
    },
    "memory.recall_reranker_top_k" => %{
      value: 20,
      type: "integer",
      desc: "Maximum Recall V2 candidates sent to the reranker (allowed range 1..500)"
    },
    "memory.event_gap_grace_seconds" => %{
      value: 60,
      type: "integer",
      desc: "Final session processing gap grace in seconds (allowed range 1..3600)"
    },
    "memory.host_batch_max_events" => %{
      value: 100,
      type: "integer",
      desc: "Maximum events in one host capture upload batch (allowed range 1..100)"
    },
    "memory.host_batch_max_bytes" => %{
      value: 524_288,
      type: "integer",
      desc: "Maximum uncompressed host capture batch bytes (allowed range 1..524288)"
    },
    "memory.host_spool_max_bytes" => %{
      value: 67_108_864,
      type: "integer",
      desc: "Default host capture spool capacity in bytes (allowed range 1..1073741824)"
    },
    "memory.host_spool_max_age_days" => %{
      value: 30,
      type: "integer",
      desc: "Host capture unacknowledged-event age warning in days (allowed range 1..3660)"
    },
    "memory.session_stale_after_seconds" => %{
      value: 10_800,
      type: "integer",
      desc: "Session inactivity before fallback closure in seconds (allowed range 60..10800)"
    },
    "memory.fallback_sweep_batch_size" => %{
      value: 100,
      type: "integer",
      desc: "Maximum stale-session candidates per fallback sweep (allowed range 1..500)"
    },
    "memory.activity_retention_days" => %{
      value: 730,
      type: "integer",
      desc: "Durable memory activity retention in days (allowed range 1..3660)"
    },
    "memory.replay_enabled" => %{
      value: true,
      type: "boolean",
      desc: "Enable canonical replay reads"
    },
    "memory.replay_import_enabled" => %{
      value: false,
      type: "boolean",
      desc: "Allow trusted host-local replay import dispatch"
    },
    "memory.replay_max_events" => %{
      value: 1_000,
      type: "integer",
      desc: "Maximum replay events per bounded load (1..10000)"
    },
    "memory.replay_import_max_files" => %{
      value: 200,
      type: "integer",
      desc: "Maximum files per host-local replay import (1..1000)"
    },
    "memory.replay_import_max_entries" => %{
      value: 100_000,
      type: "integer",
      desc: "Maximum entries per host-local replay import (1..1000000)"
    },
    "memory.replay_import_max_bytes" => %{
      value: 1_073_741_824,
      type: "integer",
      desc: "Maximum bytes per host-local replay import (1..1073741824)"
    },
    "memory.lesson_auto_extract" => %{
      value: true,
      type: "boolean",
      desc: "Produce automatic lesson candidates when an LLM is configured"
    },
    "memory.lesson_auto_promote" => %{
      value: false,
      type: "boolean",
      desc: "Enable threshold-gated automatic lesson promotion"
    },
    "memory.lesson_promote_confidence" => %{
      value: 0.85,
      type: "float",
      desc: "Minimum automatic lesson promotion confidence (allowed range 0..1)"
    },
    "memory.lesson_promote_sources" => %{
      value: 2,
      type: "integer",
      desc:
        "Minimum independent evidence and source diversity for lesson promotion (allowed range 1..100)"
    },
    "memory.lesson_decay_enabled" => %{
      value: true,
      type: "boolean",
      desc: "Apply bounded lesson retrieval-utility decay"
    },
    "memory.lesson_decay_archive_days" => %{
      value: 180,
      type: "integer",
      desc: "Archive lessons inactive for this many days (allowed range 1..3660)"
    },
    "memory.crystals_enabled" => %{
      value: true,
      type: "boolean",
      desc: "Generate crystals when an LLM is configured"
    },
    "memory.crystal_session_enabled" => %{
      value: true,
      type: "boolean",
      desc: "Enable session crystallization"
    },
    "memory.crystal_action_enabled" => %{
      value: true,
      type: "boolean",
      desc: "Enable action-chain crystallization"
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

  @type expectation :: {String.t(), term()}

  @doc "Get several setting values from one serialized snapshot."
  @spec get_many([String.t()]) :: %{String.t() => term()}
  def get_many(keys) when is_list(keys) do
    GenServer.call(__MODULE__, {:get_many, keys})
  end

  @doc "Set a value only when all expected settings still match."
  @spec set_if(String.t(), term(), [expectation()]) ::
          :ok | {:error, {:condition_failed, String.t()}} | {:error, term()}
  def set_if(key, value, expectations)
      when is_binary(key) and is_list(expectations) do
    GenServer.call(__MODULE__, {:set_if, key, value, expectations})
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
  def handle_call({:get_many, keys}, _from, state) do
    values = Map.new(keys, fn key -> {key, get(key)} end)
    {:reply, values, state}
  end

  def handle_call({:set, key, value}, _from, state) do
    persist_setting(key, value, state)
  end

  def handle_call({:set_if, key, value, expectations}, _from, state) do
    case get(key) do
      current when current === value ->
        {:reply, :ok, state}

      _current ->
        case Enum.find(expectations, fn {expected_key, expected_value} ->
               get(expected_key) !== expected_value
             end) do
          nil ->
            persist_setting(key, value, state)

          {failed_key, _expected_value} ->
            {:reply, {:error, {:condition_failed, failed_key}}, state}
        end
    end
  end

  # --- Private ---

  defp persist_setting(key, value, state) do
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
