defmodule Relayixir.Proxy.Upstream do
  @moduledoc """
  Upstream descriptor and route resolution.
  """

  @type t :: %__MODULE__{
          scheme: atom() | nil,
          host: String.t() | nil,
          port: non_neg_integer() | nil,
          path_prefix_rewrite: String.t() | nil,
          request_timeout: non_neg_integer(),
          connect_timeout: non_neg_integer(),
          first_byte_timeout: non_neg_integer(),
          websocket?: boolean(),
          host_forward_mode: :preserve | :rewrite_to_upstream | :route_defined,
          allowed_methods: [String.t()] | nil,
          inject_request_headers: [{String.t(), String.t()}],
          pool_size: non_neg_integer() | nil,
          max_response_body_size: non_neg_integer() | nil,
          max_request_body_size: non_neg_integer() | nil,
          metadata: map()
        }

  @default_request_timeout 60_000
  @default_connect_timeout 5_000
  @default_first_byte_timeout 30_000
  @default_max_response_body_size 10_485_760
  @default_max_request_body_size 8_388_608

  defstruct [
    :scheme,
    :host,
    :port,
    :path_prefix_rewrite,
    request_timeout: @default_request_timeout,
    connect_timeout: @default_connect_timeout,
    first_byte_timeout: @default_first_byte_timeout,
    websocket?: false,
    host_forward_mode: :preserve,
    allowed_methods: nil,
    inject_request_headers: [],
    pool_size: nil,
    max_response_body_size: @default_max_response_body_size,
    max_request_body_size: @default_max_request_body_size,
    metadata: %{}
  ]

  alias Relayixir.Config.{RouteConfig, UpstreamConfig}

  @doc """
  Resolves the upstream for a given `Plug.Conn` based on configured routes and upstreams.
  """
  @spec resolve(Plug.Conn.t()) :: {:ok, t()} | {:error, atom()}
  def resolve(%Plug.Conn{} = conn) do
    host = conn.host
    path = conn.request_path

    case RouteConfig.find_route(host, path) do
      nil ->
        {:error, :route_not_found}

      route ->
        case UpstreamConfig.get_upstream(route.upstream_name) do
          nil ->
            {:error, :route_not_found}

          upstream_config ->
            upstream = build_upstream(upstream_config, route)
            {:ok, upstream}
        end
    end
  end

  defp build_upstream(config, route) do
    %__MODULE__{
      scheme: Map.get(config, :scheme, :http),
      host: Map.fetch!(config, :host),
      port: Map.get(config, :port, 80),
      path_prefix_rewrite: Map.get(config, :path_prefix_rewrite),
      request_timeout: get_timeout(route, config, :request_timeout, @default_request_timeout),
      connect_timeout: get_timeout(route, config, :connect_timeout, @default_connect_timeout),
      first_byte_timeout:
        get_timeout(route, config, :first_byte_timeout, @default_first_byte_timeout),
      websocket?: Map.get(route, :websocket, false),
      host_forward_mode: Map.get(route, :host_forward_mode, :preserve),
      allowed_methods: Map.get(route, :allowed_methods),
      inject_request_headers: Map.get(route, :inject_request_headers, []),
      pool_size: Map.get(config, :pool_size),
      max_response_body_size:
        Map.get(config, :max_response_body_size, @default_max_response_body_size),
      max_request_body_size:
        Map.get(config, :max_request_body_size, @default_max_request_body_size),
      metadata: Map.get(config, :metadata, %{})
    }
  end

  defp get_timeout(route, config, key, default) do
    route_timeouts = Map.get(route, :timeouts, %{})
    Map.get(route_timeouts, key) || Map.get(config, key) || default
  end
end
