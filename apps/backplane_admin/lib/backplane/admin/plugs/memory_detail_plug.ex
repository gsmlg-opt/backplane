defmodule Backplane.Admin.MemoryDetailPlug do
  @moduledoc false

  import Plug.Conn

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

    with {:ok, partition} <- recall_partition(conn.query_params),
         {:ok, _run, _candidates} <- safe_recall_get(id, partition) do
      conn
    else
      {:error, :unavailable} -> unavailable(conn)
      {:error, _reason} -> not_found(conn)
    end
  end

  def call(%{path_params: %{"id" => id}, path_info: ["memory", "lessons", _]} = conn, _opts) do
    conn = fetch_query_params(conn)

    with {:ok, partition} <- recall_partition(conn.query_params) do
      guard_resource(conn, safe_lesson_get(id, partition))
    else
      {:error, _reason} -> not_found(conn)
    end
  end

  def call(%{path_params: %{"id" => id}, path_info: ["memory", "crystals", _]} = conn, _opts) do
    conn = fetch_query_params(conn)

    with {:ok, partition} <- recall_partition(conn.query_params) do
      guard_resource(conn, safe_crystal_get(id, partition))
    else
      {:error, _reason} -> not_found(conn)
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

    with {:ok, partition} <- recall_partition(conn.query_params) do
      guard_resource(conn, safe_crystal_source(kind, crystal_id, source_id, partition))
    else
      {:error, _reason} -> not_found(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp guard_resource(conn, {:ok, _resource}), do: conn

  defp guard_resource(conn, {:error, :not_found}) do
    not_found(conn)
  end

  defp guard_resource(conn, {:error, _reason}) do
    unavailable(conn)
  end

  defp recall_partition(params) do
    with {:ok, host_id} <- partition_value(params["host"]),
         {:ok, client_id} <- partition_value(params["client"]),
         {:ok, scope} <- partition_value(params["scope"]),
         {:ok, namespace} <- partition_value(params["namespace"]) do
      {:ok, %{host_id: host_id, client_id: client_id, scope: scope, namespace: namespace}}
    end
  end

  defp partition_value(value) when is_binary(value) do
    value = String.trim(value)
    if value != "" and byte_size(value) <= 512, do: {:ok, value}, else: {:error, :not_found}
  end

  defp partition_value(_value), do: {:error, :not_found}

  defp safe_recall_get(id, partition) do
    Store.get(id, partition)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe_lesson_get(id, partition) do
    Lessons.get_admin(id, partition)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe_crystal_get(id, partition) do
    Crystals.get(id, partition)
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
