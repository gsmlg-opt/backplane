defmodule Backplane.HostAgent.Diagnostics.Ingress do
  @moduledoc "Source-authenticated local intake with a bound on simultaneous request bodies."

  import Plug.Conn

  alias Backplane.DiagnosticsClient.Receipt
  alias Backplane.HostAgent.Diagnostics.{Sources, Spool}
  alias Backplane.HostAgent.Diagnostics.Collectors.Runner

  @max_active 8
  @max_batch_bytes 512 * 1024

  def init(opts) do
    %{
      config: opts[:diagnostics] || %{},
      spool: opts[:spool] || Spool,
      active: :atomics.new(2, signed: false)
    }
  end

  def call(conn, %{config: %{enabled: true} = config} = state) do
    case authenticate(conn, Map.get(config, :sources, %{})) do
      {:ok, source} -> dispatch(conn, state, source)
      {:error, :unauthorized} -> respond(conn, 401, %{"code" => "unauthorized"})
    end
  end

  def call(conn, _state), do: respond(conn, 404, %{"code" => "diagnostics_disabled"})

  defp dispatch(
         %{method: "GET", path_info: ["diagnostics", "v1", "status"]} = conn,
         state,
         source
       ) do
    admitted(conn, state.active, 2, 1, fn ->
      case call_store(fn -> Spool.health(state.spool, source.id, :infinity) end) do
        {:ok, rows} -> respond(conn, 200, %{"enabled" => source.enabled, "queue" => rows})
        {:error, _} -> respond(conn, 503, %{"code" => "persistence_unavailable"})
      end
    end)
  end

  defp dispatch(
         %{method: "POST", path_info: ["diagnostics", "v1", "events"]} = conn,
         state,
         source
       ) do
    if source.enabled do
      admitted(conn, state.active, 1, @max_active, fn -> accept(conn, state, source) end)
    else
      respond(conn, 403, %{"code" => "source_disabled"})
    end
  end

  defp dispatch(conn, _state, _source), do: respond(conn, 404, %{"code" => "unknown_route"})

  defp admitted(conn, active, slot, limit, operation) do
    size = :atomics.add_get(active, slot, 1)

    try do
      if size <= limit, do: operation.(), else: respond(conn, 429, %{"code" => "ingress_busy"})
    after
      :atomics.sub(active, slot, 1)
    end
  end

  defp accept(conn, state, source) do
    case read_body(conn, length: @max_batch_bytes + 1, read_length: @max_batch_bytes + 1) do
      {:ok, body, changed} ->
        case Receipt.decode_batch(body, :local) do
          {:ok, batch_id, items} ->
            case call_store(fn -> Spool.ingest(state.spool, source, batch_id, items) end) do
              {:error, _} ->
                respond(changed, 503, %{"code" => "persistence_unavailable"})

              receipt ->
                maybe_sample(state.config, source.id, items, receipt["receipts"])
                respond(changed, 200, receipt)
            end

          {:error, :batch_too_large} ->
            respond(changed, 413, %{"code" => "batch_too_large"})

          {:error, reason} ->
            respond(changed, 400, %{"code" => Atom.to_string(reason)})
        end

      {:more, _body, changed} ->
        respond(changed, 413, %{"code" => "batch_too_large"})

      {:error, _reason} ->
        respond(conn, 400, %{"code" => "invalid_batch"})
    end
  end

  defp maybe_sample(%{collector_targets: [_ | _] = targets}, source_id, items, replies) do
    new_failure? =
      items
      |> Enum.zip(replies)
      |> Enum.any?(fn
        {%{"event" => %{"event_type" => type}}, %{"status" => "stored"}} ->
          type in ~w(exception handled_error worker_exit)

        _ ->
          false
      end)

    if new_failure? do
      Enum.find_value(targets, fn
        %{"source_id" => ^source_id, "id" => target} -> Runner.trigger(target)
        _ -> nil
      end)
    end
  end

  defp maybe_sample(_config, _source_id, _, _), do: :ok

  defp authenticate(conn, sources) do
    with [id] <- get_req_header(conn, Sources.source_header()),
         ["Bearer " <> token] <- get_req_header(conn, "authorization") do
      Sources.authenticate(sources, id, token)
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Formata.JSON.encode!(body))
  end

  defp call_store(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :persistence_unavailable}
  end
end
