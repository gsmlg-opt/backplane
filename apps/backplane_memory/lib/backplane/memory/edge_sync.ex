defmodule Backplane.Memory.EdgeSync do
  @moduledoc "Stateless, explicitly versioned canonical host memory delivery."
  alias Backplane.Memory.{Config, EdgeSync.PostgresStore}

  @type subject ::
          Ecto.UUID.t()
          | %{
              :kind => :host_agent,
              :host_id => Ecto.UUID.t(),
              :auth_token_id => Ecto.UUID.t(),
              :scopes => [String.t()],
              optional(:source_client_id) => String.t() | nil
            }

  @spec negotiate(subject(), map()) :: {:ok, map()} | {:error, map()}
  def negotiate(host, offer), do: safe(fn -> do_negotiate(host, offer) end)

  defp do_negotiate(host, offer) when is_map(offer) do
    with {:ok, _} <- subject_host(host), :ok <- valid_offer(offer) do
      memory = offer["memory"] || offer["memory_v2"]

      cond do
        not is_map(memory) or not valid_protocol_offered?(memory["offers"]) ->
          {:error, :unsupported_protocol}

        offer["selected"] not in [nil, "host_memory", "host_memory.v2"] ->
          {:error, :unsupported_protocol}

        Config.host_sync_enabled?() or "memory_access.v1" in Map.get(memory, "extensions", []) ->
          store().negotiate(host, memory)

        true ->
          {:error, :protocol_disabled}
      end
    end
  end

  defp do_negotiate(_, _), do: {:error, :invalid_request}

  defp valid_protocol_offered?(offers) when is_list(offers) do
    "host_memory" in offers or "host_memory.v2" in offers
  end

  defp valid_protocol_offered?(_), do: false

  @spec next(subject(), map()) :: {:ok, map()} | {:error, map()}
  def next(host, request) do
    safe(fn ->
      with :ok <- request_valid(host, request),
           :ok <- request_fields(request, :next),
           true <- is_integer(request["applied_revision"]) and request["applied_revision"] >= 0,
           {:ok, limits} <- limits(request) do
        store().next(host, request, limits)
      else
        false -> {:error, :invalid_request}
        error -> error
      end
    end)
  end

  @spec ack(subject(), map()) :: {:ok, map()} | {:error, map()}
  def ack(host, request) do
    safe(fn ->
      with :ok <- request_valid(host, request),
           :ok <- request_fields(request, :ack),
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
    with {:ok, _} <- subject_host(host) do
      cond do
        is_nil(request["protocol"]) ->
          {:error, :invalid_request}

        request["protocol"] not in ["host_memory", "host_memory.v2"] ->
          {:error, :unsupported_protocol}

        not Config.host_sync_enabled?() ->
          {:error, :protocol_disabled}

        not is_map(request["partition"]) ->
          {:error, :invalid_request}

        true ->
          :ok
      end
    end
  end

  defp request_valid(_, _), do: {:error, :invalid_request}

  defp request_fields(request, operation) do
    allowed =
      case operation do
        :next ->
          ~w(protocol partition access applied_revision max_changes max_frame_bytes snapshot_id next_chunk_index)

        :ack ->
          ~w(protocol partition access batch_id status applied_revision snapshot_id next_chunk_index chunk_hash integrity_hash max_changes max_frame_bytes)
      end

    if Enum.all?(Map.keys(request), &(&1 in allowed)), do: :ok, else: {:error, :invalid_request}
  end

  defp valid_offer(offer) do
    memory = offer["memory"] || offer["memory_v2"]

    cond do
      is_nil(memory) ->
        {:error, :unsupported_protocol}

      is_map(memory) and memory["protocol"] == "host_memory.v1" ->
        {:error, :unsupported_protocol}

      not is_map(memory) ->
        {:error, :invalid_request}

      not is_list(memory["offers"]) or not Enum.all?(memory["offers"], &is_binary/1) ->
        {:error, :invalid_request}

      not is_list(memory["partitions"]) or length(memory["partitions"]) > 1000 ->
        {:error, :invalid_request}

      not is_nil(memory["extensions"]) and
          (not is_list(memory["extensions"]) or length(memory["extensions"]) > 20 or
             not Enum.all?(memory["extensions"], &is_binary/1)) ->
        {:error, :invalid_request}

      true ->
        case limits(memory) do
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

  defp subject_host(%{kind: :host_agent, host_id: host}), do: uuid(host)
  defp subject_host(host), do: uuid(host)

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
