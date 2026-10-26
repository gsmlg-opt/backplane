defmodule Backplane.Memory.Context do
  @moduledoc "Builds the session context block injected into Claude Code on SessionStart."

  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Profiles
  alias Backplane.Memory.Recall.Pipeline

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
        case Pipeline.run(
               recall_attrs(kind, project, session_id, partition),
               trace?: false,
               post_fusion_opts: [limit: 5]
             ) do
          {:ok, %{results: [_ | _] = memories}} ->
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
    opts
    |> Map.new()
    |> Backplane.Memory.PartitionIdentity.validate()
  end

  defp recall_attrs(kind, project, session_id, partition) do
    attrs =
      partition
      |> Map.take([:memory_space_id, :host_id, :client_id, :source_client_id, :scope, :namespace])
      |> Map.put(:query, recall_query(kind, project))
      |> Map.put(:project, project)
      |> Map.put(:token_budget, @token_budget)

    if kind == :pre_compact and is_binary(session_id) and session_id != "",
      do: Map.put(attrs, :session_id, session_id),
      else: attrs
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
      |> Enum.reject(&(&1.memory_type == :procedural))
      |> Enum.map(fn memory ->
        "- #{memory.content} [#{memory.kind}:#{compact_id(memory.id)}]"
      end)
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
