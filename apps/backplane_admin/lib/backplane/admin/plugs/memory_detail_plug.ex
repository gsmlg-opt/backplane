defmodule Backplane.Admin.MemoryDetailPlug do
  @moduledoc false

  use Backplane.Admin, :html

  import Plug.Conn

  alias Backplane.Memory.Operations.Inventory
  import Backplane.Admin.MemoryOperatorComponents, only: [browse_scope: 1]

  alias Backplane.Memory.Operations
  alias Backplane.Memory.Lessons
  alias Backplane.Memory.{Crystals, CrystalSources}
  alias Backplane.Memory.Recall.Store

  def init(opts), do: opts

  def call(%{path_params: %{"stream_id" => id}} = conn, _opts) do
    guard_resource(conn, Operations.get_stream(id))
  end

  def call(%{path_params: %{"event_id" => id}} = conn, _opts) do
    guard_resource(conn, Operations.get_event(id))
  end

  def call(%{path_params: %{"recall_run_id" => id}} = conn, _opts) do
    conn = fetch_query_params(conn)

    with {:ok, partition} <- Inventory.identity(:recall, id, browse_scope(conn.query_params)),
         {:ok, _run, _candidates} <- safe_recall_get(id, partition) do
      conn
    else
      {:error, :unavailable} -> unavailable(conn)
      {:error, _reason} -> not_found(conn)
    end
  end

  def call(%{path_params: %{"id" => id}, path_info: ["memory", "lessons", _]} = conn, _opts) do
    conn = fetch_query_params(conn)

    with {:ok, partition} <- Inventory.identity(:lesson, id, browse_scope(conn.query_params)) do
      guard_detail(conn, safe_lesson_get(id, partition), "/memory/lessons")
    else
      {:error, :unavailable} -> unavailable(conn)
      {:error, _reason} -> guard_detail(conn, {:error, :not_found}, "/memory/lessons")
    end
  end

  def call(%{path_params: %{"id" => id}, path_info: ["memory", "crystals", _]} = conn, _opts) do
    conn = fetch_query_params(conn)

    with {:ok, partition} <- Inventory.identity(:crystal, id, browse_scope(conn.query_params)) do
      guard_detail(conn, safe_crystal_get(id, partition), "/memory/crystals")
    else
      {:error, :unavailable} -> unavailable(conn)
      {:error, _reason} -> guard_detail(conn, {:error, :not_found}, "/memory/crystals")
    end
  end

  def call(
        %{
          path_params: %{"id" => crystal_id, "source_id" => source_id},
          path_info: ["memory", "crystals", _, "sources", kind, _]
        } = conn,
        _opts
      ) do
    conn = fetch_query_params(conn)

    with {:ok, partition} <-
           Inventory.identity(:crystal, crystal_id, browse_scope(conn.query_params)) do
      guard_resource(conn, safe_crystal_source(kind, crystal_id, source_id, partition))
    else
      {:error, _reason} -> not_found(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp guard_detail(conn, {:ok, _resource}, _path), do: conn

  defp guard_detail(conn, {:error, :not_found}, path) do
    query =
      conn.query_params
      |> Map.take(~w(memory_space_id host client scope namespace project repository))
      |> URI.encode_query()

    return_path = path <> "?" <> query
    body = missing_detail(%{return_path: return_path}) |> Phoenix.HTML.Safe.to_iodata()
    conn |> put_resp_content_type("text/html") |> send_resp(404, body) |> halt()
  end

  defp guard_detail(conn, {:error, _reason}, _path), do: unavailable(conn)

  defp missing_detail(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="sunshine">
      <head><meta name="viewport" content="width=device-width, initial-scale=1" /><title>Memory unavailable</title>
        <link rel="stylesheet" href={DuskmoonBundler.static_path(Backplane.Admin.Endpoint, "/assets/css/app.css", profile: :backplane_admin, outdir: "priv/static/assets")} />
      </head>
      <body class="bg-surface text-on-surface p-6">
        <.dm_card id="memory-missing-detail" padding="lg">
          <h1 class="text-2xl font-semibold">Memory unavailable</h1>
          <p class="mt-3">This record is missing, deleted, or unavailable for the current filters.</p>
          <.link href={@return_path} class="mt-4 inline-block text-primary underline">Return to Memory inventory</.link>
        </.dm_card>
      </body>
    </html>
    """
  end

  defp guard_resource(conn, {:ok, _resource}), do: conn

  defp guard_resource(conn, {:error, :not_found}) do
    not_found(conn)
  end

  defp guard_resource(conn, {:error, _reason}) do
    unavailable(conn)
  end

  defp safe_recall_get(id, partition) do
    Store.get(id, partition)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe_lesson_get(id, partition) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         do: Lessons.get_admin(id, partition),
         else: (_ -> {:error, :not_found})
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe_crystal_get(id, partition) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         do: Crystals.get(id, partition),
         else: (_ -> {:error, :not_found})
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe_crystal_source("actions", crystal_id, source_id, partition),
    do: CrystalSources.get_action(crystal_id, source_id, partition)

  defp safe_crystal_source("summaries", crystal_id, source_id, partition),
    do: CrystalSources.get_summary(crystal_id, source_id, partition)

  defp safe_crystal_source("sessions", crystal_id, source_id, partition),
    do: CrystalSources.get_session(crystal_id, source_id, partition)

  defp safe_crystal_source(_kind, _crystal_id, _source_id, _partition),
    do: {:error, :not_found}

  defp not_found(conn) do
    conn
    |> send_resp(404, "not found")
    |> halt()
  end

  defp unavailable(conn) do
    conn
    |> send_resp(503, "memory unavailable")
    |> halt()
  end
end
