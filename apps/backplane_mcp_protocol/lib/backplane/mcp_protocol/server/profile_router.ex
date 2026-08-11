defmodule Backplane.McpProtocol.Server.ProfileRouter do
  @moduledoc """
  Selects the session-oriented legacy path or a stateless modern profile.

  Body metadata and transport markers are inspected independently. Transport
  validation remains the responsibility of the selected executor.
  """

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Protocol.Registry

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"

  @type route :: :legacy | {:modern, Profile.t()}

  @spec route(map(), map()) :: {:ok, route()} | {:error, Error.t()}
  def route(request, transport_context) when is_map(request) and is_map(transport_context) do
    body_marker? = body_version_present?(request)
    method_marker? = request["method"] == "server/discover"
    header_marker? = modern_header_marker?(protocol_version_header(transport_context))
    modern? = body_marker? or method_marker? or header_marker?

    hard_legacy? = transport_context[:connection_era] == :legacy

    cond do
      modern? and hard_legacy? ->
        {:error,
         Error.protocol(:invalid_request, %{
           message: "Conflicting modern and legacy protocol markers"
         })}

      modern? ->
        modern_profile(request, transport_context)

      true ->
        {:ok, :legacy}
    end
  end

  defp modern_profile(request, transport_context) do
    body = body_version(request)
    header = protocol_version_header(transport_context)
    supported = modern_versions(transport_context)

    if is_binary(body) and is_binary(header) and body != header do
      mismatch_profile(body, header)
    else
      requested = requested_version(body, header, supported)

      case Registry.profile(requested) do
        {:ok, %Profile{era: :modern} = profile} ->
          if requested in supported do
            {:ok, {:modern, profile}}
          else
            unsupported_version(requested, supported)
          end

        _other ->
          unsupported_version(requested, supported)
      end
    end
  end

  defp mismatch_profile(body, header) do
    [body, header, default_modern_version()]
    |> Enum.find_value(fn version ->
      case Registry.profile(version) do
        {:ok, %Profile{era: :modern} = profile} -> profile
        _other -> nil
      end
    end)
    |> case do
      %Profile{} = profile -> {:ok, {:modern, profile}}
      nil -> unsupported_version(body, [])
    end
  end

  defp unsupported_version(requested, supported) do
    {:error,
     Error.for_version("2026-07-28", :unsupported_protocol_version, %{
       requested: requested,
       supported: supported
     })}
  end

  defp requested_version(body, header, supported) do
    cond do
      is_binary(body) ->
        body

      is_binary(header) ->
        header

      true ->
        List.first(supported) || default_modern_version()
    end
  end

  defp body_version(request), do: request |> body_meta() |> Map.get(@protocol_version_key)

  defp body_version_present?(request) do
    request
    |> body_meta()
    |> Map.has_key?(@protocol_version_key)
  end

  defp body_meta(%{"params" => %{"_meta" => meta}}) when is_map(meta), do: meta
  defp body_meta(_request), do: %{}

  defp protocol_version_header(%{protocol_version_header: version}) when is_binary(version), do: version

  defp protocol_version_header(%{headers: headers}) when is_map(headers) do
    headers
    |> Map.new(fn {name, value} -> {name |> to_string() |> String.downcase(), value} end)
    |> Map.get("mcp-protocol-version")
  end

  defp protocol_version_header(%{req_headers: headers}) when is_list(headers) do
    headers
    |> Map.new(fn {name, value} -> {name |> to_string() |> String.downcase(), value} end)
    |> Map.get("mcp-protocol-version")
  end

  defp protocol_version_header(_transport_context), do: nil

  defp modern_header_marker?(version) when is_binary(version) do
    case Registry.profile(version) do
      {:ok, %Profile{era: :legacy}} -> false
      _other -> true
    end
  end

  defp modern_header_marker?(_version), do: false

  defp modern_versions(transport_context) do
    transport_context
    |> Map.get(:supported_versions, Registry.supported_versions())
    |> Enum.filter(fn version ->
      match?({:ok, %Profile{era: :modern}}, Registry.profile(version))
    end)
    |> Enum.uniq()
  end

  defp default_modern_version do
    Enum.find(Registry.supported_versions(), fn version ->
      match?({:ok, %Profile{era: :modern}}, Registry.profile(version))
    end)
  end
end
