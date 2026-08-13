defmodule Backplane.Memory.Config do
  @moduledoc false

  alias Backplane.Memory.Audit
  alias Backplane.Settings

  @pipeline "memory.pipeline.enabled"
  @events "memory.events.enabled"
  @dual_write "memory.events.dual_write"
  @window_summaries "memory.window_summaries.enabled"
  @session_summary_v2 "memory.session_summary_v2.enabled"
  @fact_extraction_v2 "memory.fact_extraction_v2.enabled"
  @procedure_extraction_v2 "memory.procedure_extraction_v2.enabled"
  @relation_classifier "memory.relation_classifier.enabled"
  @recall_v2 "memory.recall_v2.enabled"

  @event_gap_grace_seconds "memory.event_gap_grace_seconds"
  @host_batch_max_events "memory.host_batch_max_events"
  @host_batch_max_bytes "memory.host_batch_max_bytes"
  @host_spool_max_bytes "memory.host_spool_max_bytes"
  @host_spool_max_age_days "memory.host_spool_max_age_days"
  @session_stale_after_seconds "memory.session_stale_after_seconds"
  @fallback_sweep_batch_size "memory.fallback_sweep_batch_size"
  @activity_retention_days "memory.activity_retention_days"
  @recall_trace_enabled "memory.recall_trace_enabled"
  @recall_trace_retention_days "memory.recall_trace_retention_days"
  @recall_rrf_k "memory.recall_rrf_k"
  @recall_channel_weights "memory.recall_channel_weights"
  @recall_channel_limits "memory.recall_channel_limits"
  @recall_max_per_session "memory.recall_max_per_session"
  @recall_token_budget "memory.recall_token_budget"
  @recall_reranker_enabled "memory.recall_reranker_enabled"
  @recall_reranker_top_k "memory.recall_reranker_top_k"
  @lesson_auto_extract "memory.lesson_auto_extract"
  @lesson_auto_promote "memory.lesson_auto_promote"
  @lesson_promote_confidence "memory.lesson_promote_confidence"
  @lesson_promote_sources "memory.lesson_promote_sources"
  @lesson_decay_enabled "memory.lesson_decay_enabled"
  @lesson_decay_archive_days "memory.lesson_decay_archive_days"
  @crystals_enabled "memory.crystals_enabled"
  @crystal_session_enabled "memory.crystal_session_enabled"
  @crystal_action_enabled "memory.crystal_action_enabled"
  @replay_enabled "memory.replay_enabled"
  @replay_import_enabled "memory.replay_import_enabled"
  @replay_max_events "memory.replay_max_events"
  @replay_import_max_files "memory.replay_import_max_files"
  @replay_import_max_entries "memory.replay_import_max_entries"
  @replay_import_max_bytes "memory.replay_import_max_bytes"

  @default_event_gap_grace_seconds 60
  @default_host_spool_max_bytes 64 * 1024 * 1024
  @default_session_stale_after_seconds 10_800
  @default_fallback_sweep_batch_size 100
  @default_activity_retention_days 730
  @default_recall_channel_weights %{fts: 1.0, vector: 1.0, graph: 1.0}
  @default_recall_channel_limits %{fts: 50, vector: 50, graph: 50}

  @editable_settings [
    {@host_batch_max_events, "Host batch maximum events", :integer, 1, 100,
     :host_batch_max_events},
    {@host_batch_max_bytes, "Host batch maximum bytes", :integer, 1, 524_288,
     :host_batch_max_bytes},
    {@host_spool_max_bytes, "Host spool maximum bytes", :integer, 1, 1_073_741_824,
     :host_spool_max_bytes},
    {@host_spool_max_age_days, "Host spool maximum age days", :integer, 1, 3_660,
     :host_spool_max_age_days},
    {@event_gap_grace_seconds, "Event gap grace seconds", :integer, 1, 3_600,
     :event_gap_grace_seconds},
    {@activity_retention_days, "Activity retention days", :integer, 1, 3_660,
     :activity_retention_days},
    {@recall_trace_enabled, "Recall traces", :boolean, nil, nil, :recall_trace_enabled?},
    {@recall_trace_retention_days, "Recall trace retention days", :integer, 1, 3_660,
     :recall_trace_retention_days},
    {@recall_max_per_session, "Recall maximum per session", :integer, 1, 100,
     :recall_max_per_session},
    {@lesson_auto_extract, "Lesson auto extraction", :boolean, nil, nil,
     :lesson_auto_extract?},
    {@lesson_auto_promote, "Lesson auto promotion", :boolean, nil, nil,
     :lesson_auto_promote?},
    {@lesson_promote_confidence, "Lesson promotion confidence", :float, 0.0, 1.0,
     :lesson_promote_confidence},
    {@lesson_promote_sources, "Lesson promotion sources", :integer, 1, 100,
     :lesson_promote_sources},
    {@lesson_decay_enabled, "Lesson decay", :boolean, nil, nil, :lesson_decay_enabled?},
    {@crystals_enabled, "Crystals", :boolean, nil, nil, :crystals_enabled?},
    {@crystal_session_enabled, "Session crystals", :boolean, nil, nil,
     :crystal_session_enabled?},
    {@crystal_action_enabled, "Action crystals", :boolean, nil, nil,
     :crystal_action_enabled?},
    {@replay_enabled, "Replay", :boolean, nil, nil, :replay_enabled?},
    {@replay_import_enabled, "Replay import", :boolean, nil, nil, :replay_import_enabled?},
    {@replay_max_events, "Replay maximum events", :integer, 1, 10_000,
     :replay_max_events},
    {@replay_import_max_files, "Replay import maximum files", :integer, 1, 1_000,
     :replay_import_max_files},
    {@replay_import_max_entries, "Replay import maximum entries", :integer, 1, 1_000_000,
     :replay_import_max_entries},
    {@replay_import_max_bytes, "Replay import maximum bytes", :integer, 1, 1_073_741_824,
     :replay_import_max_bytes}
  ]

  @doc "Returns the finite typed operator-editable Memory V2 setting inventory."
  def editable_settings do
    Enum.map(@editable_settings, fn {key, label, type, minimum, maximum, accessor} ->
      %{
        key: key,
        label: label,
        type: type,
        minimum: minimum,
        maximum: maximum,
        configured: Settings.get(key),
        effective: apply(__MODULE__, accessor, [])
      }
    end)
  end

  @doc "Validates, persists, and content-safely audits a trusted operator setting change."
  def update_setting(key, raw_value, %{actor: actor, request_id: request_id, correlation_id: correlation_id})
      when is_binary(key) and is_binary(actor) and is_binary(request_id) and
             is_binary(correlation_id) do
    with {:ok, spec} <- fetch_setting_spec(key),
         {:ok, value} <- parse_setting(raw_value, spec),
         previous = Settings.get(key),
         :ok <- Settings.set(key, value),
         :ok <-
           Audit.log("memory.config.set", actor, %{setting: key}, %{
             request_id: request_id,
             correlation_id: correlation_id,
             setting: key,
             old_class: value_class(previous),
             new_class: value_class(value),
             changed: previous !== value,
             content_exposed: false
           }) do
      {:ok, value}
    end
  end

  def update_setting(_key, _raw_value, _context), do: {:error, :unauthorized}

  defp fetch_setting_spec(key) do
    case Enum.find(@editable_settings, fn {candidate, _, _, _, _, _} -> candidate == key end) do
      nil -> {:error, :unknown_setting}
      {_, _, type, minimum, maximum, _} -> {:ok, {type, minimum, maximum}}
    end
  end

  defp parse_setting(value, {:boolean, nil, nil}) when value in [true, "true"], do: {:ok, true}
  defp parse_setting(value, {:boolean, nil, nil}) when value in [false, "false"], do: {:ok, false}

  defp parse_setting(value, {:integer, minimum, maximum}) do
    with {:ok, integer} <- parse_integer(value),
         true <- integer >= minimum and integer <= maximum do
      {:ok, integer}
    else
      _ -> {:error, :invalid_value}
    end
  end

  defp parse_setting(value, {:float, minimum, maximum}) do
    with {:ok, number} <- parse_number(value),
         true <- number >= minimum and number <= maximum do
      {:ok, number / 1}
    else
      _ -> {:error, :invalid_value}
    end
  end

  defp parse_setting(_value, _spec), do: {:error, :invalid_value}

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_integer(_value), do: :error
  defp parse_number(value) when is_number(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp parse_number(_value), do: :error
  defp value_class(true), do: "boolean:true"
  defp value_class(false), do: "boolean:false"
  defp value_class(value) when is_integer(value), do: "integer"
  defp value_class(value) when is_float(value), do: "float"
  defp value_class(nil), do: "unset"
  defp value_class(_value), do: "other"

  def pipeline_enabled?, do: enabled?(@pipeline)
  def events_enabled?, do: pipeline_enabled?() and enabled?(@events)
  def dual_write?, do: events_enabled?() and enabled?(@dual_write)

  def window_summaries_enabled?,
    do: pipeline_enabled?() and enabled?(@window_summaries)

  def session_summary_v2_enabled?,
    do: pipeline_enabled?() and enabled?(@session_summary_v2)

  def fact_extraction_v2_enabled?,
    do: pipeline_enabled?() and enabled?(@fact_extraction_v2)

  def procedure_extraction_v2_enabled?,
    do: pipeline_enabled?() and enabled?(@procedure_extraction_v2)

  def relation_classifier_enabled?,
    do: pipeline_enabled?() and enabled?(@relation_classifier)

  def recall_v2_enabled?, do: pipeline_enabled?() and enabled?(@recall_v2)

  @doc "Returns the final-processing gap grace in seconds (inclusive range 1..3600; default 60)."
  def event_gap_grace_seconds do
    bounded_integer(@event_gap_grace_seconds, @default_event_gap_grace_seconds, 1, 3_600)
  end

  def host_batch_max_events, do: bounded_integer(@host_batch_max_events, 100, 1, 100)
  def host_batch_max_bytes, do: bounded_integer(@host_batch_max_bytes, 524_288, 1, 524_288)

  def host_spool_max_bytes,
    do: bounded_integer(@host_spool_max_bytes, @default_host_spool_max_bytes, 1, 1_073_741_824)

  def host_spool_max_age_days, do: bounded_integer(@host_spool_max_age_days, 30, 1, 3_660)

  @doc "Returns the stale-session threshold in seconds (inclusive range 60..10800; default 10800)."
  def session_stale_after_seconds do
    bounded_integer(
      @session_stale_after_seconds,
      @default_session_stale_after_seconds,
      60,
      10_800
    )
  end

  @doc "Returns the fallback sweep candidate limit (inclusive range 1..500; default 100)."
  def fallback_sweep_batch_size do
    bounded_integer(
      @fallback_sweep_batch_size,
      @default_fallback_sweep_batch_size,
      1,
      500
    )
  end

  @doc "Returns durable activity retention in days (inclusive range 1..3660; default 730)."
  def activity_retention_days do
    bounded_integer(@activity_retention_days, @default_activity_retention_days, 1, 3_660)
  end

  @doc "Whether privacy-filtered recall trace persistence is enabled (default true)."
  def recall_trace_enabled?, do: strict_boolean(@recall_trace_enabled, true)

  @doc "Returns recall trace retention in days (inclusive range 1..3660; default 30)."
  def recall_trace_retention_days,
    do: bounded_integer(@recall_trace_retention_days, 30, 1, 3_660)

  @doc "Returns the weighted RRF constant (inclusive range 1..1000; default 60)."
  def recall_rrf_k, do: bounded_integer(@recall_rrf_k, 60, 1, 1_000)

  @doc "Returns complete bounded FTS/vector/graph weights."
  def recall_channel_weights do
    value =
      bounded_channel_map(
        Backplane.Settings.get(@recall_channel_weights),
        @default_recall_channel_weights,
        &valid_weight?/1
      )

    if Enum.any?(value, fn {_channel, weight} -> weight > 0 end),
      do: value,
      else: @default_recall_channel_weights
  end

  @doc "Returns complete bounded FTS/vector/graph candidate limits."
  def recall_channel_limits do
    bounded_channel_map(
      Backplane.Settings.get(@recall_channel_limits),
      @default_recall_channel_limits,
      &(is_integer(&1) and &1 in 1..500)
    )
  end

  @doc "Returns the per-session diversity cap (inclusive range 1..100; default 3)."
  def recall_max_per_session,
    do: bounded_integer(@recall_max_per_session, 3, 1, 100)

  @doc "Returns the default recall token budget (inclusive range 1..100000; default 4096)."
  def recall_token_budget,
    do: bounded_integer(@recall_token_budget, 4_096, 1, 100_000)

  @doc "Whether optional top-K recall reranking is enabled (default false)."
  def recall_reranker_enabled?, do: strict_boolean(@recall_reranker_enabled, false)

  @doc "Returns the reranker input cap (inclusive range 1..500; default 20)."
  def recall_reranker_top_k,
    do: bounded_integer(@recall_reranker_top_k, 20, 1, 500)

  def lesson_auto_extract?, do: llm_configured?() and strict_boolean(@lesson_auto_extract, true)
  def lesson_auto_promote?, do: strict_boolean(@lesson_auto_promote, false)
  def lesson_promote_confidence, do: bounded_number(@lesson_promote_confidence, 0.85, 0.0, 1.0)
  def lesson_promote_sources, do: bounded_integer(@lesson_promote_sources, 2, 1, 100)
  def lesson_decay_enabled?, do: strict_boolean(@lesson_decay_enabled, true)
  def lesson_decay_archive_days, do: bounded_integer(@lesson_decay_archive_days, 180, 1, 3_660)
  def crystals_enabled?, do: llm_configured?() and strict_boolean(@crystals_enabled, true)

  def crystal_session_enabled?,
    do: crystals_enabled?() and strict_boolean(@crystal_session_enabled, true)

  def crystal_action_enabled?,
    do: crystals_enabled?() and strict_boolean(@crystal_action_enabled, true)

  def replay_enabled?, do: pipeline_enabled?() and strict_boolean(@replay_enabled, true)

  def replay_import_enabled?,
    do: replay_enabled?() and strict_boolean(@replay_import_enabled, false)

  def replay_max_events, do: bounded_integer(@replay_max_events, 1_000, 1, 10_000)
  def replay_import_max_files, do: bounded_integer(@replay_import_max_files, 200, 1, 1_000)

  def replay_import_max_entries,
    do: bounded_integer(@replay_import_max_entries, 100_000, 1, 1_000_000)

  def replay_import_max_bytes,
    do: bounded_integer(@replay_import_max_bytes, 1_073_741_824, 1, 1_073_741_824)

  defp enabled?(key), do: Backplane.Settings.get(key) == true

  defp strict_boolean(key, default) do
    case Backplane.Settings.get(key) do
      value when is_boolean(value) -> value
      _invalid -> default
    end
  end

  defp bounded_integer(key, default, minimum, maximum) do
    case Backplane.Settings.get(key) do
      value when is_integer(value) and value >= minimum and value <= maximum -> value
      _invalid -> default
    end
  end

  defp bounded_number(key, default, minimum, maximum) do
    case Backplane.Settings.get(key) do
      value when is_number(value) and value >= minimum and value <= maximum -> value / 1
      _invalid -> default
    end
  end

  defp llm_configured? do
    not is_nil(Application.get_env(:backplane_memory, :llm_client))
  end

  defp bounded_channel_map(value, default, validator) when is_map(value) do
    expected = MapSet.new(~w(fts vector graph))

    if MapSet.new(Map.keys(value)) == expected and
         Enum.all?(value, fn {_key, item} -> validator.(item) end) do
      %{
        fts: normalize_number(value["fts"], default.fts),
        vector: normalize_number(value["vector"], default.vector),
        graph: normalize_number(value["graph"], default.graph)
      }
    else
      default
    end
  end

  defp bounded_channel_map(_value, default, _validator), do: default
  defp valid_weight?(value), do: is_number(value) and value >= 0 and value <= 100

  defp normalize_number(value, default) when is_float(default) and is_integer(value),
    do: value / 1

  defp normalize_number(value, _default), do: value
end
