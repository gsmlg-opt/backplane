defmodule Relayixir do
  @moduledoc """
  Elixir-native HTTP/WebSocket reverse proxy built on Bandit + Plug + Mint.

  ## Runtime Configuration

  Routes and upstreams can be updated at any time without restarting the application.

  ### From code

      Relayixir.load(
        routes: [
          %{host_match: "*", path_prefix: "/api", upstream_name: "backend"}
        ],
        upstreams: %{
          "backend" => %{scheme: :http, host: "localhost", port: 4001}
        }
      )

  ### From application config

  Set config in `config/runtime.exs` (or any config file) and call `Relayixir.reload/0`:

      config :relayixir,
        routes: [%{host_match: "*", path_prefix: "/", upstream_name: "app"}],
        upstreams: %{"app" => %{scheme: :http, host: "localhost", port: 4001}}

  Then call `Relayixir.reload()` to apply changes. On startup, the application
  automatically loads config from `Application.get_env(:relayixir, :routes)` and
  `Application.get_env(:relayixir, :upstreams)` if present.
  """

  alias Relayixir.Config.{RouteConfig, UpstreamConfig, HookConfig}

  @doc """
  Atomically loads routes and upstreams from a keyword list.

  Accepts `:routes` (list of route maps) and/or `:upstreams` (map of name → config).
  Omitting a key leaves the existing config unchanged.
  """
  @spec load(keyword()) :: :ok
  def load(config) when is_list(config) do
    if routes = config[:routes], do: RouteConfig.put_routes(routes)
    if upstreams = config[:upstreams], do: UpstreamConfig.put_upstreams(upstreams)

    if hooks = config[:hooks] do
      if Keyword.has_key?(hooks, :on_request_complete) do
        HookConfig.put_on_request_complete(hooks[:on_request_complete])
      end

      if Keyword.has_key?(hooks, :on_ws_frame) do
        HookConfig.put_on_ws_frame(hooks[:on_ws_frame])
      end
    end

    :ok
  end

  @doc """
  Reloads routes and upstreams from the application environment.

  Reads `Application.get_env(:relayixir, :routes)` and
  `Application.get_env(:relayixir, :upstreams)`. Useful after `Config.Provider`
  or any runtime config change.
  """
  @spec reload() :: :ok
  def reload do
    config = [
      routes: Application.get_env(:relayixir, :routes, []),
      upstreams: Application.get_env(:relayixir, :upstreams, %{})
    ]

    config =
      case Application.get_env(:relayixir, :hooks) do
        nil -> config
        hooks -> Keyword.put(config, :hooks, hooks)
      end

    load(config)
  end

  @doc """
  Configure routes for the proxy. Replaces all existing routes.
  """
  defdelegate configure_routes(routes), to: RouteConfig, as: :put_routes

  @doc """
  Configure upstreams for the proxy. Replaces all existing upstreams.
  """
  defdelegate configure_upstreams(upstreams), to: UpstreamConfig, as: :put_upstreams
end
