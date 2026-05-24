defmodule BackplaneMemory.Slots.Reflect do
  @moduledoc """
  Stop-hook slot reflection. Scans recent observations for TODO/FIXME/blocked patterns
  and updates pending_items, session_patterns, and project_context slots.
  Only runs when memory.reflect_enabled=true.
  """

  import Ecto.Query
  alias BackplaneMemory.Observations.Observation
  alias BackplaneMemory.Slots

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Run slot reflection for a session. Returns :ok or {:skip, reason}."
  def run(session_id) do
    if Backplane.Settings.get("memory.reflect_enabled") == "true" do
      observations = recent_observations(session_id)
      update_pending_items(observations)
      update_session_patterns(observations)
      :ok
    else
      {:skip, :disabled}
    end
  end

  defp recent_observations(session_id) do
    repo().all(
      from(o in Observation,
        where: o.session_id == ^session_id,
        order_by: [desc: o.created_at],
        limit: 100
      )
    )
  end

  defp update_pending_items(observations) do
    items =
      observations
      |> Enum.flat_map(fn obs ->
        Regex.scan(~r/(?:TODO|FIXME|blocked|needs|should):\s*(.+)/i, obs.content)
        |> Enum.map(fn [_, item] -> "- #{String.trim(item)} [obs:#{obs.id}]" end)
      end)
      |> Enum.take(5)

    if items != [] do
      new_lines = Enum.join(items, "\n")

      case Slots.read("pending_items") do
        {:ok, slot} ->
          new_content = (slot.content <> "\n" <> new_lines) |> String.trim()
          Slots.write("pending_items", new_content, "reflect")

        _ ->
          Slots.write("pending_items", new_lines, "reflect")
      end
    end
  end

  defp update_session_patterns(observations) do
    tool_counts =
      observations
      |> Enum.reject(&is_nil(&1.tool_name))
      |> Enum.frequencies_by(& &1.tool_name)
      |> Enum.sort_by(fn {_, c} -> c end, :desc)
      |> Enum.take(5)
      |> Enum.map(fn {tool, count} -> "#{tool}: #{count}x" end)
      |> Enum.join(", ")

    if tool_counts != "" do
      Slots.write("session_patterns", "Tools used: #{tool_counts}", "reflect")
    end
  end
end
