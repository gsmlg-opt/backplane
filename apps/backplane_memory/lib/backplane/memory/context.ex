defmodule Backplane.Memory.Context do
  @moduledoc "Builds the session context block injected into Claude Code on SessionStart."

  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Memories.Search
  alias Backplane.Memory.Profiles

  @token_budget 2000

  @doc """
  Build context string for a project. Returns nil when injection is disabled or
  when there is nothing to inject.
  """
  def build(project, session_id \\ nil, opts \\ []) do
    with true <- Backplane.Settings.get("memory.inject_context") == "true",
         {:ok, partition} <- partition_from_opts(opts) do
      kind = Keyword.get(opts, :kind, :session_start)
      parts = lifecycle_header(kind, session_id)

      parts =
        if kind == :session_start and Keyword.get(opts, :include_profile, true) do
          case Profiles.get(project, partition) do
            nil -> parts
            profile -> parts ++ [format_profile(profile)]
          end
        else
          parts
        end

      parts =
        case Search.hybrid_recall(
               recall_query(kind, project),
               recall_opts(kind, project, session_id, opts)
             ) do
          {:ok, [_ | _] = memories} ->
            case format_memories(kind, memories) do
              "" -> parts
              section -> parts ++ [section]
            end

          _ ->
            parts
        end

      parts =
        case Lessons.top(partition, project: project, limit: 5) do
          {:ok, [_ | _] = lessons} -> parts ++ [format_lessons(kind, lessons)]
          _ -> parts
        end

      parts
      |> Enum.join("\n\n")
      |> truncate_to_budget()
      |> case do
        "" -> nil
        text -> text
      end
    else
      _disabled_or_untrusted -> nil
    end
  end

  defp partition_from_opts(opts) do
    partition = Map.new(opts)

    if Enum.all?([:host_id, :client_id, :scope, :namespace], fn key ->
         value = partition[key]
         is_binary(value) and value != ""
       end) do
      {:ok, Map.take(partition, [:host_id, :client_id, :scope, :namespace])}
    else
      {:error, :unauthorized}
    end
  end

  defp recall_opts(kind, project, session_id, opts) do
    recall_opts =
      opts
      |> Keyword.take([:scope, :host_id, :client_id, :namespace])
      |> Keyword.put(:project, project)
      |> Keyword.put(:writeback_fn, fn _ids -> :ok end)
      |> Keyword.put(:limit, 5)

    if kind == :pre_compact and is_binary(session_id) and session_id != "",
      do: Keyword.put(recall_opts, :session, session_id),
      else: recall_opts
  end

  defp recall_query(:pre_compact, project),
    do: "#{project} decisions active files errors unresolved actions facts"

  defp recall_query(_kind, project), do: project

  defp lifecycle_header(:pre_compact, session_id),
    do: ["## Pre-Compact Continuity\nCurrent session: #{session_id}"]

  defp lifecycle_header(_kind, _session_id), do: []

  defp format_profile(profile) do
    concepts = profile.top_concepts |> Map.keys() |> Enum.take(5) |> Enum.join(", ")
    files = profile.top_files |> Map.keys() |> Enum.take(5) |> Enum.join(", ")

    profile_state =
      if DateTime.diff(DateTime.utc_now(), profile.updated_at, :second) >= 3600,
        do: "stale",
        else: "current"

    """
    ## Project Profile: #{profile.project}
    Top concepts: #{concepts}
    Top files: #{files}
    Sessions: #{profile.session_count}, Observations: #{profile.total_observations}
    Profile revision: #{DateTime.to_iso8601(profile.updated_at)}
    Profile state: #{profile_state}
    """
  end

  defp format_memories(kind, memories) do
    items =
      memories
      |> Enum.reject(&(&1.memory_type == "procedural"))
      |> Enum.map(fn memory -> "- #{memory.content} [memory:#{compact_id(memory.id)}]" end)
      |> Enum.join("\n")

    heading = if kind == :pre_compact, do: "Current Session Sources", else: "Relevant Memories"
    if items == "", do: "", else: "## #{heading}\n#{items}"
  end

  defp format_lessons(kind, lessons) do
    items =
      lessons
      |> Enum.map(fn lesson ->
        evidence =
          lesson.evidence_ids |> Enum.take(2) |> Enum.map(&compact_id/1) |> Enum.join(",")

        suffix = if evidence == "", do: "", else: " evidence:#{evidence}"
        "- #{lesson.content} [lesson:#{compact_id(lesson.id)}#{suffix}]"
      end)
      |> Enum.join("\n")

    heading = if kind == :pre_compact, do: "Relevant Lessons", else: "Active Lessons"
    "## #{heading}\n#{items}"
  end

  defp compact_id(id), do: String.slice(id, 0, 8)

  defp truncate_to_budget(text) do
    max_chars = @token_budget * 4

    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "\n[truncated]"
    else
      text
    end
  end
end
