defmodule Backplane.McpProtocol.Client.InputHandler do
  @moduledoc false

  alias Backplane.McpProtocol.Client.Elicitation
  alias Backplane.McpProtocol.Client.Sampling
  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Server.Frame
  alias Backplane.McpProtocol.Server.Modern.RequestContext
  alias Backplane.McpProtocol.Server.Modern.Result

  @modern_version "2026-07-28"

  @spec resolve(map(), State.t()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(input_requests, %State{} = state) when is_map(input_requests) do
    with :ok <- validate(input_requests, state) do
      Enum.reduce_while(input_requests, {:ok, %{}}, fn {key, request}, {:ok, responses} ->
        case resolve_request(request, state) do
          {:ok, response} -> {:cont, {:ok, Map.put(responses, key, response)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  def resolve(_input_requests, %State{}), do: invalid()

  defp validate(input_requests, state) do
    {:ok, profile} = Registry.profile(@modern_version)

    context = %RequestContext{
      profile: profile,
      protocol_version: @modern_version,
      client_capabilities: state.capabilities,
      request_meta: %{},
      request: %{"method" => "tools/call", "params" => %{}},
      method: "tools/call",
      request_id: "input-validation"
    }

    outcome =
      {:reply,
       %{
         "resultType" => "input_required",
         "inputRequests" => input_requests
       }, Frame.new()}

    case Result.normalize(
           "tools/call",
           outcome,
           context,
           %{server_info: %{"name" => "client-input-validator", "version" => "1"}}
         ) do
      {:ok, _validated} -> :ok
      {:error, %Error{reason: :missing_client_capability} = error} -> {:error, error}
      {:error, %Error{}} -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  defp resolve_request(%{"method" => "roots/list"}, state) do
    state
    |> State.list_roots()
    |> Enum.reduce_while({:ok, []}, fn
      %{uri: uri, name: name}, {:ok, roots}
      when is_binary(uri) and (is_nil(name) or is_binary(name)) ->
        if valid_file_uri?(uri) do
          root = maybe_put(%{"uri" => uri}, "name", name)
          {:cont, {:ok, [root | roots]}}
        else
          {:halt, invalid()}
        end

      _invalid, _acc ->
        {:halt, invalid()}
    end)
    |> case do
      {:ok, roots} -> {:ok, %{"roots" => Enum.reverse(roots)}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp resolve_request(%{"method" => "sampling/createMessage", "params" => params}, state) do
    Sampling.resolve(params, state)
  end

  defp resolve_request(%{"method" => "elicitation/create", "params" => params}, state) do
    Elicitation.resolve(params, state)
  end

  defp resolve_request(_request, _state), do: invalid()

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp valid_file_uri?(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) ->
        String.downcase(scheme) == "file" and
          String.starts_with?(String.downcase(uri), "file://") and
          valid_percent_encoding?(uri)

      _invalid ->
        false
    end
  end

  defp valid_percent_encoding?(uri) do
    uri
    |> String.replace(~r/%[0-9A-Fa-f]{2}/, "")
    |> then(&(not String.contains?(&1, "%")))
  end

  defp invalid do
    {:error, Error.protocol(:invalid_params, %{message: "Malformed MCP input request"})}
  end
end
