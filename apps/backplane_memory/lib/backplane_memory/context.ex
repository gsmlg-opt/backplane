defmodule BackplaneMemory.Context do
  @moduledoc "Builds the session context block injected into Claude Code on SessionStart."

  alias BackplaneMemory.Memories.{Profiles, Search}

  @token_budget 2000

  @doc """
  Build context string for a project. Returns nil when injection is disabled or
  when there is nothing to inject.
  """
  def build(project, _session_id \\ nil) do
    if Backplane.Settings.get("memory.inject_context") != "true" do
      nil
    else
      parts = []

      parts =
        case Profiles.get(project) do
          nil -> parts
          profile -> parts ++ [format_profile(profile)]
        end

      parts =
        case Search.hybrid_recall(project, limit: 5, scope: project) do
          {:ok, [_ | _] = memories} -> parts ++ [format_memories(memories)]
          _ -> parts
        end

      parts
      |> Enum.join("\n\n")
      |> truncate_to_budget()
      |> case do
        "" -> nil
        text -> text
      end
    end
  end

  defp format_profile(profile) do
    concepts = profile.top_concepts |> Map.keys() |> Enum.take(5) |> Enum.join(", ")
    files = profile.top_files |> Map.keys() |> Enum.take(5) |> Enum.join(", ")

    """
    ## Project Profile: #{profile.project}
    Top concepts: #{concepts}
    Top files: #{files}
    Sessions: #{profile.session_count}, Observations: #{profile.total_observations}
    """
  end

  defp format_memories(memories) do
    items =
      memories
      |> Enum.map(fn m -> "- #{m.content}" end)
      |> Enum.join("\n")

    "## Recent Memories\n#{items}"
  end

  defp truncate_to_budget(text) do
    max_chars = @token_budget * 4

    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "\n[truncated]"
    else
      text
    end
  end
end
