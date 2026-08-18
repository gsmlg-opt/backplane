defmodule Backplane.Proxy.ProtocolClient do
  @moduledoc """
  Builds the protocol-package client contract for a configured MCP upstream.

  This adapter keeps process naming, protocol preference normalization, and
  request-local authentication in one place. It does not own a process or
  reconnect policy.

  Original caller request-ID forwarding is deferred until the protocol package
  exposes a request-context-aware provider seam. The current zero-arity provider
  emits authentication headers only and intentionally ignores process-local
  Logger metadata, so no construction, caller, or invocation request ID is
  captured or forwarded.
  """

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Transport.StreamableHTTP.Headers
  alias Backplane.Proxy.AuthInjector

  @legacy_protocol_version "2025-11-25"
  @modern_protocol_version "2026-07-28"
  @default_timeout 30_000

  @doc "Return the local registry name for an upstream protocol client."
  @spec client_name(String.t()) :: GenServer.name()
  def client_name(prefix) do
    {:via, Registry, {Backplane.Proxy.ProcessRegistry, {prefix, :client}}}
  end

  @doc "Return the local registry name for an upstream protocol transport."
  @spec transport_name(String.t()) :: GenServer.name()
  def transport_name(prefix) do
    {:via, Registry, {Backplane.Proxy.ProcessRegistry, {prefix, :transport}}}
  end

  @doc "Normalize persisted protocol selection at the runtime seam."
  @spec protocol_preference(term()) :: String.t() | :auto
  def protocol_preference(%{protocol_version: "auto"}), do: :auto

  def protocol_preference(%{protocol_version: version})
      when version in [@legacy_protocol_version, @modern_protocol_version],
      do: version

  def protocol_preference(_config), do: @legacy_protocol_version

  @doc "Build exact options for `Backplane.McpProtocol.Client.child_spec/1`."
  @spec client_options(map()) :: keyword()
  def client_options(%{prefix: prefix} = config) do
    [
      name: client_name(prefix),
      transport_name: transport_name(prefix),
      protocol_version: protocol_preference(config),
      client_info: %{"name" => "backplane", "version" => Backplane.MCP.Info.version()},
      capabilities: %{},
      timeout: timeout(config),
      transport: transport_options(config)
    ]
  end

  @doc "Return a sanitized upstream error message."
  @spec error_message(term()) :: String.t()
  def error_message(%Error{reason: reason}) when is_atom(reason), do: Atom.to_string(reason)
  def error_message(%Error{}), do: "upstream protocol error"
  def error_message(_other), do: "upstream connection error"

  defp timeout(%{timeout: timeout}) when is_integer(timeout) and timeout > 0, do: timeout
  defp timeout(_config), do: @default_timeout

  defp transport_options(%{transport: "http", url: url} = config) do
    static_headers =
      case config do
        %{headers: nil} -> %{}
        %{headers: headers} -> headers
        _missing -> %{}
      end

    {:streamable_http,
     [
       url: url,
       headers: static_headers,
       headers_provider: headers_provider(config)
     ]}
  end

  defp transport_options(%{transport: "stdio", command: command} = config) do
    args =
      case config do
        %{args: nil} -> []
        %{args: args} -> args
        _missing -> []
      end

    env =
      case config do
        %{env: nil} -> %{}
        %{env: env} -> env
        _missing -> %{}
      end

    {:stdio, [command: command, args: args, env: env]}
  end

  defp headers_provider(config) do
    auth_scheme = Map.get(config, :auth_scheme)
    auth_header_name = Map.get(config, :auth_header_name)
    credential_name = Map.get(config, :credential)

    fn ->
      AuthInjector.inject([], auth_scheme, auth_header_name, credential_name)
      |> normalize_dynamic_headers()
    end
  end

  defp normalize_dynamic_headers({:ok, headers}), do: Headers.configured(headers)
  defp normalize_dynamic_headers({:error, _reason} = error), do: error
end
