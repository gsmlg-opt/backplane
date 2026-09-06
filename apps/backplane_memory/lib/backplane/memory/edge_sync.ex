defmodule Backplane.Memory.EdgeSync do
  @moduledoc "Stateless, explicitly versioned canonical host memory delivery."
  alias Backplane.Memory.{Config, EdgeSync.PostgresStore}

  @spec negotiate(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, map()}
  def negotiate(host, offer), do: safe(fn -> do_negotiate(host, offer) end)

  defp do_negotiate(host, offer) when is_map(offer) do
    with {:ok, _} <- uuid(host), :ok <- valid_offer(offer) do
      v2 = offer["memory_v2"]
      selected = offer["selected"]

      cond do
        selected == "host_memory.v2" and not Config.host_sync_v2_enabled?() ->
          {:error, :protocol_disabled}

        is_map(v2) and "host_memory.v2" in v2["offers"] and Config.host_sync_v2_enabled?() ->
          store().negotiate(host, v2)

        selected == "host_memory.v2" ->
          {:error, :unsupported_protocol}

        get_in(offer, ["memory", "protocol"]) == "host_memory.v1" and
            Config.host_sync_v1_enabled?() ->
          {:ok, %{selected: "host_memory.v1"}}

        is_map(v2) and "host_memory.v2" in v2["offers"] ->
          {:error, :protocol_disabled}

        true ->
          {:error, :unsupported_protocol}
      end
    end
  end

  defp do_negotiate(_, _), do: {:error, :invalid_request}

  @spec next(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, map()}
  def next(host, request) do
    safe(fn ->
      with :ok <- request_valid(host, request),
           true <- is_integer(request["applied_revision"]) and request["applied_revision"] >= 0,
           {:ok, limits} <- limits(request) do
        store().next(host, request, limits)
      else
        false -> {:error, :invalid_request}
        error -> error
      end
    end)
  end

  @spec ack(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, map()}
  def ack(host, request) do
    safe(fn ->
      with :ok <- request_valid(host, request),
           {:ok, _} <- uuid(request["batch_id"]),
           true <-
             request["status"] in ["applied", "progress"] and
               is_integer(request["applied_revision"]) and request["applied_revision"] >= 0 do
        store().ack(host, request)
      else
        false -> {:error, :invalid_request}
        error -> error
      end
    end)
  end

  @doc false
  def limits(map) do
    count = Map.get(map, "max_changes", 100)
    bytes = Map.get(map, "max_frame_bytes", 524_288)

    if is_integer(count) and count > 0 and is_integer(bytes) and bytes > 0,
      do: {:ok, %{max_changes: min(count, 100), max_frame_bytes: min(bytes, 524_288)}},
      else: {:error, :invalid_request}
  end

  defp request_valid(host, request) when is_map(request) do
    with {:ok, _} <- uuid(host) do
      cond do
        is_nil(request["protocol"]) -> {:error, :invalid_request}
        request["protocol"] != "host_memory.v2" -> {:error, :unsupported_protocol}
        not Config.host_sync_v2_enabled?() -> {:error, :protocol_disabled}
        not is_map(request["partition"]) -> {:error, :invalid_request}
        true -> :ok
      end
    end
  end

  defp request_valid(_, _), do: {:error, :invalid_request}

  defp valid_offer(offer) do
    v1 = offer["memory"]
    v2 = offer["memory_v2"]

    cond do
      not is_nil(v1) and not is_map(v1) ->
        {:error, :invalid_request}

      is_nil(v2) ->
        :ok

      not is_map(v2) ->
        {:error, :invalid_request}

      not is_list(v2["offers"]) or not Enum.all?(v2["offers"], &is_binary/1) ->
        {:error, :invalid_request}

      not is_list(v2["partitions"]) or length(v2["partitions"]) > 1000 ->
        {:error, :invalid_request}

      true ->
        case limits(v2) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  @doc false
  def safe(fun) do
    case fun.() do
      {:error, code} when is_atom(code) ->
        {:error,
         %{
           code: code,
           retryable:
             code in [:storage_unavailable, :transaction_conflict, :snapshot_build_unavailable]
         }}

      result ->
        result
    end
  rescue
    e in Postgrex.Error ->
      code =
        if e.postgres[:code] in [:serialization_failure, :deadlock_detected],
          do: :transaction_conflict,
          else: :storage_unavailable

      {:error, %{code: code, retryable: true}}

    _e in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      {:error, %{code: :storage_unavailable, retryable: true}}
  end

  defp store, do: Application.get_env(:backplane_memory, :edge_sync_store, PostgresStore)
end
