defmodule Backplane.Admin.Audit do
  @moduledoc """
  Append-only admin operation records; no payloads or secrets.

  Completion actions follow successful mutation results. `*_start`, `*_enqueue`
  and `*_requested` actions record initiation or acknowledgement, not completion.
  Persistence failures are logged or raised, never silently treated as durable.
  """
  import Ecto.Query
  require Logger
  alias Backplane.Admin.Audit.Event
  alias Backplane.Repo

  def record(action, target_type, target_id \\ nil) do
    changeset =
      Ecto.Changeset.change(%Event{},
        action: action,
        target_type: target_type,
        target_id: if(is_nil(target_id), do: nil, else: to_string(target_id))
      )
      |> Ecto.Changeset.validate_required([:action, :target_type])

    case Repo.insert(changeset) do
      {:ok, event} ->
        {:ok, event}

      {:error, _} = error ->
        Logger.error("Admin audit persistence failed for #{action} (#{target_type})")
        error
    end
  end

  def list(filters \\ %{}, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)
    query = from e in Event, order_by: [desc: e.inserted_at, desc: e.id], limit: ^limit

    query =
      Enum.reduce([:action, :target_type, :target_id], query, fn key, query ->
        case filters[key] do
          value when is_binary(value) and value != "" ->
            where(query, [e], field(e, ^key) == ^value)

          _ ->
            query
        end
      end)

    query =
      if filters[:since], do: where(query, [e], e.inserted_at >= ^filters.since), else: query

    query =
      if filters[:until], do: where(query, [e], e.inserted_at <= ^filters.until), else: query

    query =
      case opts[:cursor] do
        {time, id} ->
          where(query, [e], e.inserted_at < ^time or (e.inserted_at == ^time and e.id < ^id))

        nil ->
          query
      end

    Repo.all(query)
  end
end
