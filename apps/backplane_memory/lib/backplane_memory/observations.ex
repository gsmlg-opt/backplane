defmodule BackplaneMemory.Observations do
  import Ecto.Query
  alias BackplaneMemory.Observations.{Observation, Session}
  alias BackplaneMemory.Privacy.Filter

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc "Record an observation, applying privacy filter. Returns {:ok, obs} or {:error, reason}."
  def record(session_id, content, opts \\ []) do
    with {:ok, filtered} <- Filter.apply(content) do
      files = extract_files(filtered)

      attrs = %{
        session_id: session_id,
        tool_name: opts[:tool_name],
        content: filtered,
        is_error: opts[:is_error] || false,
        files: %{"paths" => files}
      }

      %Observation{} |> Observation.changeset(attrs) |> repo().insert()
    end
  end

  @doc "Register/upsert a session."
  def register_session(session_id, project) do
    %Session{}
    |> Session.changeset(%{
      session_id: session_id,
      project: project,
      started_at: DateTime.utc_now()
    })
    |> repo().insert(on_conflict: :nothing, conflict_target: [:session_id])
  end

  @doc "Mark a session as ended."
  def end_session(session_id) do
    repo().update_all(
      from(s in Session, where: s.session_id == ^session_id and is_nil(s.ended_at)),
      set: [ended_at: DateTime.utc_now()]
    )
  end

  @doc "Return observations referencing any of the listed file paths, newest first."
  def file_history(file_paths, opts \\ []) when is_list(file_paths) do
    exclude_session = opts[:exclude_session]
    limit = opts[:limit] || 50

    query =
      from(o in Observation,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements_text(?->'paths') AS p WHERE p = ANY(?))",
            o.files,
            ^file_paths
          ),
        order_by: [desc: o.created_at],
        limit: ^limit
      )

    query =
      if exclude_session do
        where(query, [o], o.session_id != ^exclude_session)
      else
        query
      end

    repo().all(query)
  end

  # Extract file paths from content using simple heuristics
  defp extract_files(content) do
    Regex.scan(
      ~r{(?:^|[\s"'`(])(/[^\s"'`)\n]+\.\w+|[a-zA-Z0-9_./\-]+/[a-zA-Z0-9_./\-]+\.\w+)},
      content
    )
    |> Enum.map(fn [_, path] -> String.trim(path) end)
    |> Enum.uniq()
    |> Enum.take(20)
  end
end
